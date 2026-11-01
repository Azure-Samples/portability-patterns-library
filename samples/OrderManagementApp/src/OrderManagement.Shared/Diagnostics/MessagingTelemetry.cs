using System.Diagnostics;
using OpenTelemetry;
using OpenTelemetry.Context.Propagation;

namespace OrderManagement.Shared.Diagnostics;

/// <summary>
/// Spans for queue publish and consume, with the W3C trace context carried in the message's own
/// properties (RabbitMQ headers, Service Bus application properties). One order is then one trace
/// from the API call through the queue to the processor and the inventory service.
/// </summary>
public static class MessagingTelemetry
{
    private static readonly TextMapPropagator Propagator = new CompositeTextMapPropagator(
        [new TraceContextPropagator(), new BaggagePropagator()]);

    /// <summary>Starts the producer span and writes its context through <paramref name="setProperty"/>.</summary>
    public static Activity? StartPublish(string system, string queue, string messageId, Action<string, string> setProperty)
    {
        var activity = OrderManagementTelemetry.ActivitySource.StartActivity($"{queue} publish", ActivityKind.Producer);
        SetTags(activity, system, queue, messageId, "send");

        var context = activity?.Context ?? Activity.Current?.Context ?? default;
        Propagator.Inject(new PropagationContext(context, Baggage.Current), setProperty,
            static (set, key, value) => set(key, value));

        return activity;
    }

    /// <summary>Starts the consumer span as a child of the context read through <paramref name="getProperty"/>.</summary>
    public static Activity? StartProcess(string system, string queue, string messageId, Func<string, string?> getProperty)
    {
        var parent = Propagator.Extract(default, getProperty,
            static (get, key) => get(key) is { } value ? [value] : []);
        Baggage.Current = parent.Baggage;

        var activity = OrderManagementTelemetry.ActivitySource.StartActivity(
            $"{queue} process", ActivityKind.Consumer, parent.ActivityContext);
        SetTags(activity, system, queue, messageId, "process");
        return activity;
    }

    public static void RecordFailure(Activity? activity, Exception exception)
    {
        activity?.SetStatus(ActivityStatusCode.Error, exception.Message);
        activity?.AddException(exception);
    }

    private static void SetTags(Activity? activity, string system, string queue, string messageId, string operation)
    {
        activity?.SetTag("messaging.system", system);
        activity?.SetTag("messaging.destination.name", queue);
        activity?.SetTag("messaging.operation.type", operation);
        activity?.SetTag("messaging.message.id", messageId);
    }
}
