using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Diagnostics;

/// <summary>
/// OpenTelemetry traces, metrics and logs for every service. Where they go is the platform's choice,
/// read from the environment like every other connection:
/// <c>APPLICATIONINSIGHTS_CONNECTION_STRING</c> sends them to Azure Monitor (with the workload
/// identity, as Application Insights has local authentication disabled); otherwise
/// <c>OTEL_EXPORTER_OTLP_ENDPOINT</c> sends them to an OTLP collector; otherwise they stay in-process.
/// </summary>
public static class TelemetryExtensions
{
    public static TBuilder AddOrderManagementTelemetry<TBuilder>(
        this TBuilder builder,
        Action<TracerProviderBuilder>? tracing = null,
        Action<MeterProviderBuilder>? metrics = null)
        where TBuilder : IHostApplicationBuilder
    {
        builder.Services.TryAddSingleton<OrderMetrics>();

        var telemetry = builder.Services.AddOpenTelemetry()
            .ConfigureResource(resource =>
            {
                // OTEL_SERVICE_NAME, set per container by the app definition, wins when present.
                if (string.IsNullOrWhiteSpace(builder.Configuration["OTEL_SERVICE_NAME"]))
                {
                    resource.AddService(builder.Environment.ApplicationName);
                }
            })
            .WithTracing(tracer =>
            {
                tracer
                    .AddSource(OrderManagementTelemetry.Name)
                    .AddSource("Npgsql")
                    .AddHttpClientInstrumentation()
                    .AddSqlClientInstrumentation();
                tracing?.Invoke(tracer);
            })
            .WithMetrics(meter =>
            {
                meter
                    .AddMeter(OrderManagementTelemetry.Name)
                    .AddMeter("Npgsql")
                    .AddHttpClientInstrumentation()
                    .AddRuntimeInstrumentation();
                metrics?.Invoke(meter);
            })
            .WithLogging(configureBuilder: null, configureOptions: options =>
            {
                options.IncludeFormattedMessage = true;
                options.IncludeScopes = true;
            });

        var appInsights = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
        if (!string.IsNullOrWhiteSpace(appInsights))
        {
            telemetry.UseAzureMonitorExporter(options =>
            {
                options.ConnectionString = appInsights;
                if (!string.IsNullOrWhiteSpace(builder.Configuration["AZURE_CLIENT_ID"]))
                {
                    options.Credential = AzureCredentialFactory.Create();
                }
            });
        }
        else if (!string.IsNullOrWhiteSpace(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]))
        {
            telemetry.UseOtlpExporter();
        }

        return builder;
    }
}
