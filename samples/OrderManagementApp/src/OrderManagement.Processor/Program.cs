using OrderManagement.Processor;
using OrderManagement.Shared.DependencyInjection;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddOrderQueue();
builder.Services.AddOrderArchive();
builder.Services.AddOrderStore();
builder.Services.AddHostedService<OrderProcessor>();

var host = builder.Build();
await host.RunAsync();
