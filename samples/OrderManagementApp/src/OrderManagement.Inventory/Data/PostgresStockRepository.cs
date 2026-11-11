using Npgsql;
using NpgsqlTypes;
using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Data;

/// <summary>PostgreSQL implementation of <see cref="IStockRepository"/>.</summary>
public sealed class PostgresStockRepository(NpgsqlDataSource dataSource) : IStockRepository
{
    public async Task<ReservationOutcome> ReserveAsync(
        Guid orderId, IReadOnlyList<ReservationLine> lines, CancellationToken cancellationToken)
    {
        var requested = lines
            .GroupBy(line => line.Sku, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Sum(line => line.Quantity), StringComparer.Ordinal);
        var skus = requested.Keys.Order(StringComparer.Ordinal).ToArray();
        var quantities = skus.Select(sku => requested[sku]).ToArray();

        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

        // Claim the order first. A concurrent call for the same order waits here until this
        // transaction ends, then finds the recorded outcome instead of reserving twice. An order
        // whose stock was released (it was dead-lettered) can be reserved again, for example when
        // it's replayed from the dead-letter queue.
        await using (var claim = new NpgsqlCommand(
            """
            INSERT INTO inventory.reservations (order_id, status, created_at)
            VALUES (@orderId, 'Pending', now())
            ON CONFLICT (order_id) DO UPDATE SET status = 'Pending', created_at = now()
            WHERE inventory.reservations.status = 'Released'
            """, connection, transaction))
        {
            claim.Parameters.AddWithValue("orderId", orderId);
            if (await claim.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) == 0)
            {
                await using var recorded = new NpgsqlCommand(
                    "SELECT status FROM inventory.reservations WHERE order_id = @orderId", connection, transaction);
                recorded.Parameters.AddWithValue("orderId", orderId);
                var status = (string)(await recorded.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false))!;
                await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
                return ReservationOutcome.Of(new ReservationResult { OrderId = orderId, Status = status });
            }
        }

        // Row locks in a fixed order, so two orders for overlapping products cannot deadlock.
        var available = new Dictionary<string, int>(StringComparer.Ordinal);
        await using (var lockRows = new NpgsqlCommand(
            "SELECT sku, available FROM inventory.products WHERE sku = ANY(@skus) ORDER BY sku FOR UPDATE",
            connection, transaction))
        {
            lockRows.Parameters.Add(new NpgsqlParameter("skus", NpgsqlDbType.Array | NpgsqlDbType.Text) { Value = skus });
            await using var reader = await lockRows.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                available[reader.GetString(0)] = reader.GetInt32(1);
            }
        }

        var unknown = skus.Where(sku => !available.ContainsKey(sku)).ToList();
        if (unknown.Count > 0)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return ReservationOutcome.Unknown(unknown);
        }

        var unavailable = skus.Where(sku => available[sku] < requested[sku]).ToList();
        var outcome = unavailable.Count == 0 ? ReservationStatus.Reserved : ReservationStatus.OutOfStock;

        if (unavailable.Count == 0)
        {
            await using var take = new NpgsqlCommand(
                """
                UPDATE inventory.products AS p SET available = p.available - r.quantity
                FROM unnest(@skus, @quantities) AS r(sku, quantity)
                WHERE p.sku = r.sku;

                INSERT INTO inventory.reservation_lines (order_id, sku, quantity)
                SELECT @orderId, r.sku, r.quantity FROM unnest(@skus, @quantities) AS r(sku, quantity);
                """, connection, transaction);
            take.Parameters.AddWithValue("orderId", orderId);
            take.Parameters.Add(new NpgsqlParameter("skus", NpgsqlDbType.Array | NpgsqlDbType.Text) { Value = skus });
            take.Parameters.Add(new NpgsqlParameter("quantities", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = quantities });
            await take.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        await using (var record = new NpgsqlCommand(
            "UPDATE inventory.reservations SET status = @status WHERE order_id = @orderId", connection, transaction))
        {
            record.Parameters.AddWithValue("orderId", orderId);
            record.Parameters.AddWithValue("status", outcome);
            await record.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);

        return ReservationOutcome.Of(new ReservationResult
        {
            OrderId = orderId,
            Status = outcome,
            UnavailableSkus = unavailable
        });
    }

    public async Task<bool> ReleaseAsync(Guid orderId, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

        // Locks the reservation first, then the product rows in SKU order, as ReserveAsync does, so
        // a release and a reservation can't deadlock.
        await using (var claim = new NpgsqlCommand(
            "SELECT status FROM inventory.reservations WHERE order_id = @orderId FOR UPDATE", connection, transaction))
        {
            claim.Parameters.AddWithValue("orderId", orderId);
            if (await claim.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) as string != ReservationStatus.Reserved)
            {
                await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
                return false;
            }
        }

        await using (var giveBack = new NpgsqlCommand(
            """
            SELECT 1 FROM inventory.products
            WHERE sku IN (SELECT sku FROM inventory.reservation_lines WHERE order_id = @orderId)
            ORDER BY sku FOR UPDATE;

            UPDATE inventory.products AS p SET available = p.available + l.quantity
            FROM inventory.reservation_lines AS l
            WHERE l.order_id = @orderId AND p.sku = l.sku;

            DELETE FROM inventory.reservation_lines WHERE order_id = @orderId;

            UPDATE inventory.reservations SET status = 'Released' WHERE order_id = @orderId;
            """, connection, transaction))
        {
            giveBack.Parameters.AddWithValue("orderId", orderId);
            await giveBack.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return true;
    }

    public async Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken)
    {
        await using var command = dataSource.CreateCommand(
            $"""
            UPDATE inventory.products SET available = available + @quantity WHERE sku = @sku
            RETURNING {PostgresProductRepository.ProductColumns}
            """);
        command.Parameters.AddWithValue("sku", sku);
        command.Parameters.AddWithValue("quantity", quantity);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? PostgresProductRepository.ReadProduct(reader)
            : null;
    }
}
