using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// Azure Service Bus implementation used by the Azure environments. The client authenticates with
/// the pod's Entra workload identity, never a connection string; the identity needs the
/// <c>Azure Service Bus Data Sender</c> and/or <c>Azure Service Bus Data Receiver</c> role on the queue.
/// <see cref="ServiceBusSender.SendMessageAsync"/> returns once Service Bus has accepted the message.
/// </summary>
public sealed class ServiceBusMessageBroker : IMessageBroker
{
    private readonly QueueOptions _options;
    private readonly ILogger<ServiceBusMessageBroker> _logger;
    private readonly ServiceBusClient _client;
    private readonly ServiceBusSender _sender;

    private ServiceBusProcessor? _processor;

    public ServiceBusMessageBroker(IOptions<QueueOptions> options, WorkloadIdentity identity, ILogger<ServiceBusMessageBroker> logger)
    {
        _options = options.Value;
        _logger = logger;

        var credential = identity.Entra?.Credential
            ?? throw new InvalidOperationException("Service Bus needs the pod's Entra workload identity.");
        _client = new ServiceBusClient(_options.Endpoint, credential, new ServiceBusClientOptions
        {
            TransportType = _options.ServiceBusTransport
        });
        _sender = _client.CreateSender(_options.QueueName);
        _logger.LogInformation("Using Azure Service Bus namespace {Namespace}, queue {Queue}", _options.Endpoint, _options.QueueName);
    }

    public async Task PublishAsync(Order order, CancellationToken cancellationToken)
    {
        var message = new ServiceBusMessage(order.ToJson())
        {
            MessageId = order.OrderId.ToString(),
            ContentType = "application/json",
            Subject = Order.OrderPlacedType
        };

        using var activity = MessagingTelemetry.StartPublish(
            "servicebus", _options.QueueName!, message.MessageId,
            (key, value) => message.ApplicationProperties[key] = value);

        try
        {
            await _sender.SendMessageAsync(message, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            MessagingTelemetry.RecordFailure(activity, ex);
            throw;
        }
    }

    public async Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken)
    {
        _processor = _client.CreateProcessor(_options.QueueName, new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = _options.MaxConcurrentMessages,
            // No prefetch: a prefetched message is locked while it waits, and its lock isn't renewed
            // until a handler takes it, so waiting messages would use up their deliveries.
            PrefetchCount = 0,
            MaxAutoLockRenewalDuration = _options.MaxAutoLockRenewalDuration
        });

        _processor.ProcessMessageAsync += async args =>
        {
            var messageId = args.Message.MessageId;
            var properties = args.Message.ApplicationProperties;
            using var activity = MessagingTelemetry.StartProcess(
                "servicebus", _options.QueueName!, messageId,
                key => properties.TryGetValue(key, out var value) ? value?.ToString() : null);
            try
            {
                // Service Bus dead-letters the message once a delivery fails at MaxDeliveryCount.
                var message = new QueueMessage(messageId, args.Message.Body.ToString())
                {
                    IsLastDelivery = args.Message.DeliveryCount >= _options.MaxDeliveryCount
                };
                await handler(message, args.CancellationToken).ConfigureAwait(false);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (args.CancellationToken.IsCancellationRequested)
            {
                // Stopping: the lock expires and Service Bus redelivers the message.
            }
            catch (Exception ex)
            {
                MessagingTelemetry.RecordFailure(activity, ex);
                _logger.LogError(ex, "Failed to process Service Bus message {MessageId} on delivery {DeliveryCount} of {MaxDeliveryCount}; abandoning",
                    messageId, args.Message.DeliveryCount, _options.MaxDeliveryCount);
                await args.AbandonMessageAsync(args.Message, cancellationToken: args.CancellationToken).ConfigureAwait(false);
            }
        };

        _processor.ProcessErrorAsync += args =>
        {
            _logger.LogError(args.Exception, "Service Bus processor error in {Operation} on {Entity}", args.ErrorSource, args.EntityPath);
            return Task.CompletedTask;
        };

        await _processor.StartProcessingAsync(cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Consuming Azure Service Bus queue {Queue}", _options.QueueName);

        try
        {
            await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Shutdown requested.
        }
        finally
        {
            await _processor.StopProcessingAsync(CancellationToken.None).ConfigureAwait(false);
        }
    }

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(_client.IsClosed || _processor is { IsProcessing: false }
            ? HealthCheckResult.Unhealthy("The Service Bus client is not running.")
            : HealthCheckResult.Healthy());

    public async ValueTask DisposeAsync()
    {
        if (_processor is not null)
        {
            await _processor.DisposeAsync().ConfigureAwait(false);
        }

        await _sender.DisposeAsync().ConfigureAwait(false);
        await _client.DisposeAsync().ConfigureAwait(false);
    }
}
