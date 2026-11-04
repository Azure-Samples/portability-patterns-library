using System.Globalization;
using System.Text;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Models;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using RabbitMQ.Client.OAuth2;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// RabbitMQ implementation used on Azure Local, where the workload must not depend on Azure Service
/// Bus. The queue, its dead-letter queue and the delivery limit belong to the platform; this only
/// publishes to and consumes from the queue.
///
/// One connection per process, recovered by the client after a network failure or a broker restart.
/// With a workload identity, the access token is renewed on the open connection before it expires
/// (<see cref="CredentialsRefresher"/>), so the broker never closes it for an expired token.
/// </summary>
public sealed class RabbitMqMessageBroker : IMessageBroker
{
    private readonly QueueOptions _options;
    private readonly ILogger<RabbitMqMessageBroker> _logger;
    private readonly ICredentialsProvider? _tokenCredentials;
    private readonly SemaphoreSlim _connectLock = new(1, 1);

    private IConnection? _connection;
    private IChannel? _publishChannel;
    private IChannel? _consumeChannel;
    private CredentialsRefresher? _refresher;

    // Cancelled when the consuming channel closes: deliveries in progress can no longer be
    // acknowledged, and the broker hands them out again after the channel recovers.
    private CancellationTokenSource _channelOpen = new();

    /// <param name="tokenCredentials">The workload's access token, where the queue gives no login.</param>
    public RabbitMqMessageBroker(
        IOptions<QueueOptions> options, ILogger<RabbitMqMessageBroker> logger, ICredentialsProvider? tokenCredentials = null)
    {
        _options = options.Value;
        _logger = logger;
        _tokenCredentials = _options.HasPassword ? null : tokenCredentials
            ?? throw new InvalidOperationException("RabbitMQ needs a login or the pod's workload identity.");
    }

    public async Task PublishAsync(Order order, CancellationToken cancellationToken)
    {
        var messageId = order.OrderId.ToString();
        var headers = new Dictionary<string, object?>();
        using var activity = MessagingTelemetry.StartPublish(
            "rabbitmq", _options.QueueName!, messageId, (key, value) => headers[key] = value);

        try
        {
            var channel = await GetPublishChannelAsync(cancellationToken).ConfigureAwait(false);

            // With publisher confirmations this returns once the broker has the message: it throws
            // when the broker refuses it, and (mandatory) when no queue takes it.
            await channel.BasicPublishAsync(
                exchange: string.Empty,
                routingKey: _options.QueueName!,
                mandatory: true,
                basicProperties: new BasicProperties
                {
                    Persistent = true,
                    ContentType = "application/json",
                    MessageId = messageId,
                    Type = Order.OrderPlacedType,
                    Headers = headers
                },
                body: Encoding.UTF8.GetBytes(order.ToJson()),
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            MessagingTelemetry.RecordFailure(activity, ex);
            throw;
        }
    }

    public async Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken)
    {
        var connection = await ConnectAsync(cancellationToken).ConfigureAwait(false);
        var concurrency = (ushort)_options.MaxConcurrentMessages;
        var channel = await connection.CreateChannelAsync(
            new CreateChannelOptions(
                publisherConfirmationsEnabled: false,
                publisherConfirmationTrackingEnabled: false,
                consumerDispatchConcurrency: concurrency),
            cancellationToken).ConfigureAwait(false);
        _consumeChannel = channel;

        channel.ChannelShutdownAsync += (_, args) =>
        {
            _logger.LogWarning("RabbitMQ channel closed ({Reason}); deliveries in progress will be redelivered", args.ReplyText);
            Interlocked.Exchange(ref _channelOpen, new CancellationTokenSource()).Cancel();
            return Task.CompletedTask;
        };

        // No more prefetched than handled at once: a prefetched message would wait unacknowledged
        // behind the ones in progress, which can take minutes while a dependency is down.
        await channel.BasicQosAsync(prefetchSize: 0, prefetchCount: concurrency, global: false, cancellationToken)
            .ConfigureAwait(false);

        var consumer = new AsyncEventingBasicConsumer(channel);
        consumer.ReceivedAsync += (_, args) => HandleAsync(channel, args, handler, cancellationToken);

        await channel.BasicConsumeAsync(_options.QueueName!, autoAck: false, consumer, cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Consuming RabbitMQ queue {Queue}", _options.QueueName);

        try
        {
            await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Shutdown requested.
        }
    }

    private async Task HandleAsync(
        IChannel channel, BasicDeliverEventArgs args, Func<QueueMessage, CancellationToken, Task> handler, CancellationToken stopping)
    {
        var messageId = args.BasicProperties.MessageId ?? args.DeliveryTag.ToString(CultureInfo.InvariantCulture);
        using var activity = MessagingTelemetry.StartProcess(
            "rabbitmq", _options.QueueName!, messageId, key => HeaderValue(args.BasicProperties, key));
        using var delivery = CancellationTokenSource.CreateLinkedTokenSource(stopping, _channelOpen.Token);

        var attempt = DeliveryAttempt(args.BasicProperties);
        var lastDelivery = attempt >= _options.MaxDeliveryCount;
        bool processed;
        try
        {
            var message = new QueueMessage(messageId, Encoding.UTF8.GetString(args.Body.Span)) { IsLastDelivery = lastDelivery };
            await handler(message, delivery.Token).ConfigureAwait(false);
            processed = true;
        }
        catch (OperationCanceledException) when (delivery.IsCancellationRequested)
        {
            // Stopping, or the channel is gone: the broker redelivers the message.
            return;
        }
        catch (Exception ex)
        {
            MessagingTelemetry.RecordFailure(activity, ex);

            // A requeued message doesn't count towards the quorum queue's delivery limit, so on the
            // last attempt the message is rejected instead, and the queue's dead-letter policy moves
            // it aside, as Service Bus does once DeliveryCount reaches MaxDeliveryCount.
            _logger.LogError(ex, "Failed to process RabbitMQ message {MessageId} on attempt {Attempt} of {MaxDeliveryCount}; {Outcome}",
                messageId, attempt, _options.MaxDeliveryCount, lastDelivery ? "dead-lettering" : "requeueing");
            processed = false;
        }

        try
        {
            if (processed)
            {
                await channel.BasicAckAsync(args.DeliveryTag, multiple: false, CancellationToken.None).ConfigureAwait(false);
            }
            else
            {
                await channel.BasicNackAsync(args.DeliveryTag, multiple: false, requeue: !lastDelivery, CancellationToken.None)
                    .ConfigureAwait(false);
            }
        }
        catch (Exception ex)
        {
            // The channel closed meanwhile; the broker redelivers the message.
            _logger.LogWarning("Could not settle RabbitMQ message {MessageId}: {Reason}", messageId, ExceptionSummary.Describe(ex));
        }
    }

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            var connection = await ConnectAsync(cancellationToken).ConfigureAwait(false);
            return (connection.IsOpen, _consumeChannel) switch
            {
                (false, _) => HealthCheckResult.Unhealthy("The RabbitMQ connection is closed; reconnecting."),
                (true, { IsOpen: false }) => HealthCheckResult.Unhealthy("The RabbitMQ consumer channel is closed; recovering."),
                _ => HealthCheckResult.Healthy()
            };
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Cannot connect to RabbitMQ.", ex);
        }
    }

    private async Task<IChannel> GetPublishChannelAsync(CancellationToken cancellationToken)
    {
        if (_publishChannel is { } existing)
        {
            return existing;
        }

        var connection = await ConnectAsync(cancellationToken).ConfigureAwait(false);
        await _connectLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return _publishChannel ??= await connection.CreateChannelAsync(
                new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _connectLock.Release();
        }
    }

    // The first connection is made on first use. Once made, the client recovers it, with its
    // channels and consumer, so it is never replaced.
    private async Task<IConnection> ConnectAsync(CancellationToken cancellationToken)
    {
        if (_connection is { } existing)
        {
            return existing;
        }

        await _connectLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_connection is { } connected)
            {
                return connected;
            }

            var endpoint = new Uri($"{(_options.TlsRequired ? "amqps" : "amqp")}://{_options.Endpoint}");
            var factory = new ConnectionFactory
            {
                HostName = endpoint.Host,
                Port = endpoint.IsDefaultPort ? (_options.TlsRequired ? 5671 : 5672) : endpoint.Port,
                AutomaticRecoveryEnabled = true,
                TopologyRecoveryEnabled = true,
                NetworkRecoveryInterval = _options.NetworkRecoveryInterval,
                ClientProvidedName = AppDomain.CurrentDomain.FriendlyName,
                // With TLS the broker's certificate must name its host and chain to a CA this process
                // trusts; on Azure Local that is the site CA the platform gives every pod.
                Ssl = new SslOption { Enabled = _options.TlsRequired, ServerName = endpoint.Host }
            };

            if (_tokenCredentials is null)
            {
                factory.UserName = _options.Username!;
                factory.Password = _options.Password!;
            }
            else
            {
                factory.CredentialsProvider = _tokenCredentials;
            }

            _logger.LogInformation(
                "Connecting to RabbitMQ at {Host}:{Port} ({Transport}) for queue {Queue} with {Auth}",
                factory.HostName, factory.Port, _options.TlsRequired ? "TLS" : "no TLS", _options.QueueName,
                _tokenCredentials is null ? "a login" : "the workload's access token");

            var connection = await factory.CreateConnectionAsync(cancellationToken).ConfigureAwait(false);
            if (_tokenCredentials is not null)
            {
                _refresher = new CredentialsRefresher(_tokenCredentials, (credentials, failure, token) =>
                    UpdateSecretAsync(connection, credentials, failure, token), CancellationToken.None);
            }

            return _connection = connection;
        }
        finally
        {
            _connectLock.Release();
        }
    }

    private async Task UpdateSecretAsync(
        IConnection connection, Credentials? credentials, Exception? failure, CancellationToken cancellationToken)
    {
        if (credentials is null)
        {
            _logger.LogWarning("Could not renew the RabbitMQ access token: {Reason}", ExceptionSummary.Describe(failure!));
            return;
        }

        try
        {
            await connection.UpdateSecretAsync(credentials.Password, "access token renewed", cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // A connection that is recovering signs in again with a fresh token.
            _logger.LogWarning("Could not hand the renewed access token to RabbitMQ: {Reason}", ExceptionSummary.Describe(ex));
        }
    }

    // 1 on the first delivery. Quorum queues count earlier deliveries in x-acquired-count.
    private static long DeliveryAttempt(IReadOnlyBasicProperties properties) =>
        properties.Headers?.TryGetValue("x-acquired-count", out var acquired) == true && acquired is not null
            ? Convert.ToInt64(acquired, CultureInfo.InvariantCulture) + 1
            : 1;

    // AMQP carries string header values as bytes.
    private static string? HeaderValue(IReadOnlyBasicProperties properties, string key) =>
        properties.Headers?.TryGetValue(key, out var value) == true
            ? value switch
            {
                byte[] bytes => Encoding.UTF8.GetString(bytes),
                null => null,
                _ => value.ToString()
            }
            : null;

    public async ValueTask DisposeAsync()
    {
        _refresher?.Dispose();
        if (_consumeChannel is not null)
        {
            await _consumeChannel.DisposeAsync().ConfigureAwait(false);
        }

        if (_publishChannel is not null)
        {
            await _publishChannel.DisposeAsync().ConfigureAwait(false);
        }

        if (_connection is not null)
        {
            await _connection.DisposeAsync().ConfigureAwait(false);
        }

        _connectLock.Dispose();
        _channelOpen.Dispose();
    }
}
