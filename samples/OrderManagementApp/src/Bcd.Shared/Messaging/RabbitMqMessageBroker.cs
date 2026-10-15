using System.Text;
using Bcd.Shared.Configuration;
using Bcd.Shared.Identity;
using Bcd.Shared.Models;
using Microsoft.Extensions.Logging;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace Bcd.Shared.Messaging;

/// <summary>
/// RabbitMQ implementation used by the local (kind) environment, where no Azure Service Bus exists.
/// </summary>
public sealed class RabbitMqMessageBroker : IMessageBroker
{
    private readonly QueueOptions _options;
    private readonly ILogger<RabbitMqMessageBroker> _logger;
    private readonly WorkloadTokenProvider? _tokenProvider;
    private readonly SemaphoreSlim _connectionLock = new(1, 1);

    private IConnection? _connection;
    private IChannel? _channel;

    public RabbitMqMessageBroker(
        QueueOptions options,
        ILogger<RabbitMqMessageBroker> logger,
        WorkloadTokenProvider? tokenProvider = null)
    {
        _options = options;
        _logger = logger;
        _tokenProvider = tokenProvider;
    }

    private async Task<IChannel> EnsureChannelAsync(CancellationToken cancellationToken)
    {
        if (_channel is { IsOpen: true })
        {
            return _channel;
        }

        await _connectionLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_channel is { IsOpen: true })
            {
                return _channel;
            }

            // A previous connection that the broker closed (expired token, restart) is released
            // here; otherwise every reconnect would leak its socket.
            await CloseQuietlyAsync().ConfigureAwait(false);

            var factory = new ConnectionFactory
            {
                HostName = _options.Host ?? "localhost",
                Port = _options.Port,
                UserName = _options.Username ?? "guest",
                Password = _options.Password ?? "guest",
                AutomaticRecoveryEnabled = true
            };

            if (_tokenProvider is not null)
            {
                // RabbitMQ's OAuth 2.0 backend takes the token as the password and ignores the
                // user name. Recovery is off because it would replay this token after it expires;
                // callers reach EnsureChannelAsync again and a fresh one is fetched instead.
                factory.UserName = string.Empty;
                factory.Password = await _tokenProvider.GetAccessTokenAsync(cancellationToken)
                    .ConfigureAwait(false);
                factory.AutomaticRecoveryEnabled = false;
            }

            _logger.LogInformation(
                "Connecting to RabbitMQ at {Host}:{Port} for queue {Queue} using {Auth}",
                factory.HostName, factory.Port, _options.QueueName,
                _tokenProvider is null ? "a password" : "an access token");

            _connection = await factory.CreateConnectionAsync(cancellationToken).ConfigureAwait(false);
            _channel = await _connection.CreateChannelAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

            await _channel.QueueDeclareAsync(
                queue: _options.QueueName,
                durable: true,
                exclusive: false,
                autoDelete: false,
                arguments: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return _channel;
        }
        finally
        {
            _connectionLock.Release();
        }
    }

    public Task PublishAsync(BusinessEvent businessEvent, CancellationToken cancellationToken) =>
        PublishJsonAsync(businessEvent.EventId.ToString(), businessEvent.EventType, businessEvent.ToJson(), cancellationToken);

    public Task PublishAsync(Order order, CancellationToken cancellationToken) =>
        PublishJsonAsync(order.OrderId.ToString(), Order.OrderPlacedType, order.ToJson(), cancellationToken);

    private async Task PublishJsonAsync(string messageId, string type, string json, CancellationToken cancellationToken)
    {
        var channel = await EnsureChannelAsync(cancellationToken).ConfigureAwait(false);
        var body = Encoding.UTF8.GetBytes(json);

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            MessageId = messageId,
            Type = type
        };

        await channel.BasicPublishAsync(
            exchange: string.Empty,
            routingKey: _options.QueueName,
            mandatory: false,
            basicProperties: properties,
            body: body,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    public async Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken)
    {
        var backoff = TimeSpan.FromSeconds(2);

        // With OAuth the broker closes the connection when the access token expires, and a broker
        // restart does the same. Each pass subscribes on a fresh channel and returns when it closes.
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var reason = await ConsumeUntilChannelClosesAsync(handler, cancellationToken).ConfigureAwait(false);
                _logger.LogWarning("RabbitMQ channel closed ({Reason}); resubscribing", reason);
                backoff = TimeSpan.FromSeconds(2);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Could not subscribe to RabbitMQ queue {Queue}; retrying in {Delay}",
                    _options.QueueName, backoff);
            }

            try
            {
                await Task.Delay(backoff, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            backoff = TimeSpan.FromSeconds(Math.Min(backoff.TotalSeconds * 2, 30));
        }
    }

    private async Task<string> ConsumeUntilChannelClosesAsync(
        Func<QueueMessage, CancellationToken, Task> handler,
        CancellationToken cancellationToken)
    {
        var channel = await EnsureChannelAsync(cancellationToken).ConfigureAwait(false);

        var closed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        channel.ChannelShutdownAsync += (_, args) =>
        {
            closed.TrySetResult(args.ReplyText);
            return Task.CompletedTask;
        };

        // The channel may have closed before the handler was attached.
        if (!channel.IsOpen)
        {
            closed.TrySetResult(channel.CloseReason?.ReplyText ?? "closed before subscribing");
        }

        await channel.BasicQosAsync(
            prefetchSize: 0,
            prefetchCount: 8,
            global: false,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        var consumer = new AsyncEventingBasicConsumer(channel);

        consumer.ReceivedAsync += async (_, args) =>
        {
            var messageId = args.BasicProperties.MessageId ?? args.DeliveryTag.ToString();
            try
            {
                var body = Encoding.UTF8.GetString(args.Body.Span);
                await handler(new QueueMessage(messageId, body), cancellationToken).ConfigureAwait(false);
                await channel.BasicAckAsync(args.DeliveryTag, multiple: false, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to process RabbitMQ message {MessageId}; requeueing", messageId);

                // Back off before requeueing. Without this a poison or transient-failure message is
                // redelivered immediately, producing a hot loop that floods the logs.
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // Shutting down.
                }

                await channel.BasicNackAsync(args.DeliveryTag, multiple: false, requeue: true, cancellationToken)
                    .ConfigureAwait(false);
            }
        };

        await channel.BasicConsumeAsync(
            queue: _options.QueueName,
            autoAck: false,
            consumer: consumer,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        _logger.LogInformation("Consuming RabbitMQ queue {Queue}", _options.QueueName);

        // Unacknowledged deliveries on a closed channel are redelivered; the SQL MERGE makes that safe.
        return await closed.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task CloseQuietlyAsync()
    {
        try
        {
            if (_channel is not null) { await _channel.DisposeAsync().ConfigureAwait(false); }
            if (_connection is not null) { await _connection.DisposeAsync().ConfigureAwait(false); }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Ignoring error while releasing a closed RabbitMQ connection");
        }
        finally
        {
            _channel = null;
            _connection = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_channel is not null)
        {
            await _channel.DisposeAsync().ConfigureAwait(false);
        }

        if (_connection is not null)
        {
            await _connection.DisposeAsync().ConfigureAwait(false);
        }

        _connectionLock.Dispose();
    }
}
