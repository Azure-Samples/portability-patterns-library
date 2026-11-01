using OrderManagement.Processor;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;

var builder = Host.CreateApplicationBuilder(args);

builder.AddOrderManagementTelemetry();
builder.Services.AddOrderQueue();
builder.Services.AddOrderArchive();
builder.Services.AddOrderStore();
builder.Services.AddInventoryClient();
builder.Services.AddHostedService<OrderProcessor>();

var host = builder.Build();
await host.RunAsync();