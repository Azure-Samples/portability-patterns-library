using Microsoft.Extensions.Options;
using OrderManagement.Processor;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;
using Polly;

// A worker: it consumes the queue. It serves HTTP only for its health probes.
var builder = WebApplication.CreateBuilder(args);

builder.AddOrderManagementTelemetry();
builder.Services.AddOrderQueue(builder.Configuration);
builder.Services.AddOrderArchive(builder.Configuration);
builder.Services.AddOrderStore(builder.Configuration);
builder.Services.AddInventoryClient(builder.Configuration);

builder.Services.AddOptions<ProcessorOptions>()
    .BindConfiguration(ProcessorOptions.SectionName)
    .ValidateOnStart();

// One delivery's work, retried as a whole while its failures are transient: every step is idempotent.
builder.Services.AddResiliencePipeline(OrderProcessor.PipelineName, (pipeline, context) =>
    context.ServiceProvider.GetRequiredService<IOptions<ProcessorOptions>>().Value.ConfigurePipeline(
        pipeline, context.ServiceProvider.GetRequiredService<ILogger<OrderProcessor>>()));

builder.Services.AddSingleton<OrderProcessor>();
builder.Services.AddHostedService(services => services.GetRequiredService<OrderProcessor>());

// Live while the consumer runs; ready while the queue and the database are reachable.
builder.Services.AddHealthChecks().AddCheck<ConsumerHealthCheck>("consumer", tags: [HealthTags.Live]);

var app = builder.Build();
app.MapHealthChecks("/healthz", new() { Predicate = check => check.Tags.Contains(HealthTags.Live) });
app.MapHealthChecks("/healthz/ready", new() { Predicate = check => check.Tags.Contains(HealthTags.Ready) });
app.Run();
