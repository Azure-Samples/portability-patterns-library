namespace OrderManagement.Shared.Diagnostics;

/// <summary>
/// Produces short, readable descriptions of exceptions for retry logging.
///
/// The Azure SDK wraps transport failures in an <see cref="AggregateException"/> containing one
/// inner exception per retry attempt, each with a full stack trace. Logging that object directly on
/// every attempt buries the actual reason under hundreds of lines of identical stack frames.
/// </summary>
public static class ExceptionSummary
{
    public static string Describe(Exception exception)
    {
        if (exception is AggregateException aggregate)
        {
            var messages = aggregate.Flatten().InnerExceptions
                .Select(inner => inner.GetBaseException().Message)
                .Distinct(StringComparer.Ordinal)
                .ToArray();

            if (messages.Length > 0)
            {
                return string.Join("; ", messages);
            }
        }

        return exception.GetBaseException().Message;
    }
}
