using Azure.Messaging.ServiceBus;
using Bcd.Shared.Configuration;
using Bcd.Shared.Identity;
using Bcd.Shared.Models;
using Microsoft.Extensions.Logging;

namespace Bcd.Shared.Messaging;

/// <summary>
/// Azure Service Bus implementation used by the Azure environments.
///
/// The client is constructed from the namespace FQDN plus a <c>TokenCredential</c>, never a
/// connection string, so the worker authenticates with its federated managed identity. The identity
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

        if (!string.IsNullOrWhiteSpace(options.ConnectionString))
        {
            // Escape hatch for local experimentation only; the Azure recipes never emit this.
            _logger.LogWarning("Connecting to Azure Service Bus with a connection string. Prefer managed identity.");
            _client = new ServiceBusClient(options.ConnectionString, clientOptions);
        }
        else
        {
            var fqdn = options.NamespaceFqdn ?? throw new InvalidOperationException(
                "Azure Service Bus requires either 'namespaceFqdn' or 'connectionString'.");

            _logger.LogInformation(
                "Connecting to Azure Service Bus namespace {Namespace} using workload identity (client id {ClientId})",
                fqdn, options.WorkloadIdentityClientId ?? "<default>");

            var credential = AzureCredentialFactory.Create(options.WorkloadIdentityClientId);
            _client = new ServiceBusClient(fqdn, credential, clientOptions);
        }

        _sender = _client.CreateSender(options.QueueName);
    }

    public async Task PublishAsync(BusinessEvent businessEvent, CancellationToken cancellationToken)
    {
        var message = new ServiceBusMessage(businessEvent.ToJson())
        {
            MessageId = businessEvent.EventId.ToString(),
            ContentType = "application/json",
            Subject = businessEvent.EventType
        };

        message.ApplicationProperties["region"] = businessEvent.Region;
        message.ApplicationProperties["severity"] = businessEvent.Severity;

        await _sender.SendMessageAsync(message, cancellationToken).ConfigureAwait(false);
    }

    public async Task PublishAsync(Order order, CancellationToken cancellationToken)
    {
        var message = new ServiceBusMessage(order.ToJson())
        {
            MessageId = order.OrderId.ToString(),
            ContentType = "application/json",
            Subject = Order.OrderPlacedType
        };

        await _sender.SendMessageAsync(message, cancellationToken).ConfigureAwait(false);
    }

    public async Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken)
    {
        _processor = _client.CreateProcessor(_options.QueueName, new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = 4,
            PrefetchCount = 8
        });

        _processor.ProcessMessageAsync += async args =>
        {
            var messageId = args.Message.MessageId;
            try
            {
                var body = args.Message.Body.ToString();
                await handler(new QueueMessage(messageId, body), args.CancellationToken).ConfigureAwait(false);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
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
