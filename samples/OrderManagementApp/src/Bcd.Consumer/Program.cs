using Bcd.Consumer;
using Bcd.Shared.DependencyInjection;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddBcdQueue();
builder.Services.AddBcdArchiveStore();
builder.Services.AddBcdRecordStore();
builder.Services.AddBcdOrderStore();
builder.Services.AddHostedService<ConsumerWorker>();

var host = builder.Build();
await host.RunAsync();
