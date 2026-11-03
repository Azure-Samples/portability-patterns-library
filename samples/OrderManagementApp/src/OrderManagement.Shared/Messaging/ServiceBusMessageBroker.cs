using Azure.Messaging.ServiceBus;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Models;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// Azure Service Bus implementation used by the Azure environments.
///
/// The client is constructed from the namespace host name plus a <c>TokenCredential</c>, never a
/// connection string, so the application authenticates with its federated managed identity. The identity
/// needs the <c>Azure Service Bus Data Sender</c> and/or <c>Azure Service Bus Data Receiver</c>
/// role on the namespace or queue.
/// </summary>
public sealed class ServiceBusMessageBroker : IMessageBroker
{
    private readonly QueueOptions _options;
    private readonly ILogger<ServiceBusMessageBroker> _logger;
    private readonly ServiceBusClient _client;
    private readonly ServiceBusSender _sender;

    private ServiceBusProcessor? _processor;

    public ServiceBusMessageBroker(QueueOptions options, ILogger<ServiceBusMessageBroker> logger)
    {
        _options = options;
        _logger = logger;

        var clientOptions = new ServiceBusClientOptions
        {
            TransportType = ServiceBusTransportType.AmqpWebSockets
        };

        _logger.LogInformation("Connecting to Azure Service Bus namespace {Namespace} using workload identity", options.Endpoint);
        _client = new ServiceBusClient(options.Endpoint, AzureCredentialFactory.Create(), clientOptions);

        _sender = _client.CreateSender(options.QueueName);
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
            "servicebus", _options.QueueName, message.MessageId,
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
            MaxConcurrentCalls = 4,
            // No prefetch: a prefetched message is locked while it waits, and its lock isn't renewed
            // until a handler takes it. With handlers waiting minutes for the inventory service, the
            // waiting messages' locks would expire and use up their deliveries.
            PrefetchCount = 0,
            // Longer than the processor's wait for the inventory service, so the lock is still
            // held when it finishes.
            MaxAutoLockRenewalDuration = TimeSpan.FromMinutes(10)
        });

        _processor.ProcessMessageAsync += async args =>
        {
            var messageId = args.Message.MessageId;
            var properties = args.Message.ApplicationProperties;
            using var activity = MessagingTelemetry.StartProcess(
                "servicebus", _options.QueueName, messageId,
                key => properties.TryGetValue(key, out var value) ? value?.ToString() : null);
            try
            {
                var body = args.Message.Body.ToString();
                // Service Bus dead-letters the message once a delivery fails at MaxDeliveryCount.
                var message = new QueueMessage(messageId, body)
                {
                    IsLastDelivery = args.Message.DeliveryCount >= _options.MaxDeliveryCount
                };
                await handler(message, args.CancellationToken).ConfigureAwait(false);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                MessagingTelemetry.RecordFailure(activity, ex);
                _logger.LogError(ex, "Failed to process Service Bus message {MessageId}; abandoning", messageId);
                await args.AbandonMessageAsync(args.Message, cancellationToken: args.CancellationToken)
                    .ConfigureAwait(false);
            }
        };

        _processor.ProcessErrorAsync += args =>
        {
            _logger.LogError(
                args.Exception,
                "Service Bus processor error in {Operation} on {Entity}",
                args.ErrorSource, args.EntityPath);
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
