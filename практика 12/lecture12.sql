-- Практика 12. Секционирование

-- 1. Проверка стенда: 200 / 250 / 2400 / 7200 / 12
SELECT (SELECT COUNT(*) FROM l12_customers) AS customers,
       (SELECT COUNT(*) FROM l12_products) AS products,
       (SELECT COUNT(*) FROM l12_orders) AS orders,
       (SELECT COUNT(*) FROM l12_order_items) AS items,
       (SELECT COUNT(*) FROM pg_inherits WHERE inhparent = 'l12_orders'::regclass) AS partitions;

-- Строки по секциям: 12 месяцев, от 185 до 205 строк
SELECT tableoid::regclass AS partition_name, COUNT(*)
FROM l12_orders GROUP BY 1 ORDER BY 1;

-- Позиции ссылаются на (order_id, order_date): первичный ключ секционированной таблицы
-- обязан включать ключ секционирования order_date
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'l12_order_items'::regclass AND contype = 'f';

-- 2. Сравнение планов
-- Все заказы: Append по 12 секциям, actual rows 2400, Buffers 24, 0.5 ms
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM l12_orders;

-- Май 2025: одна секция l12_orders_2025_05, actual rows 203, Buffers 2, 0.05 ms
-- Исключены 11 секций (pruning)
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM l12_orders
WHERE order_date >= '2025-05-01' AND order_date < '2025-06-01';

-- 3. Клиент и период
-- Индекс создан seed на родителе (и на каждой секции)
SELECT indexname FROM pg_indexes WHERE tablename = 'l12_orders';

-- Клиент 1200098, май: одна секция, Seq Scan, actual rows 2, Buffers 2
-- В секции 203 строки, читать её целиком дешевле индекса
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM l12_orders
WHERE customer_id = 1200098 AND order_date >= '2025-05-01' AND order_date < '2025-06-01';

-- Без запрета Seq Scan индекс внутри секции не выбирается; с запретом: Bitmap Index Scan
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM l12_orders
WHERE customer_id = 1200098 AND order_date >= '2025-05-01' AND order_date < '2025-06-01';
RESET enable_seqscan;

-- 4. Выручка paid по месяцам: по amount
SELECT date_trunc('month', order_date)::date AS month, SUM(amount) AS amount_sum
FROM l12_orders WHERE status = 'paid' GROUP BY 1 ORDER BY 1;

-- По позициям (JOIN по обоим полям ключа)
SELECT date_trunc('month', o.order_date)::date AS month, SUM(i.quantity * i.unit_price) AS items_sum
FROM l12_orders o
JOIN l12_order_items i ON i.order_id = o.order_id AND i.order_date = o.order_date
WHERE o.status = 'paid'
GROUP BY 1 ORDER BY 1;

-- Контроль: amount 7575800.00, позиции 40642330.00 (amount задан отдельно, поэтому суммы разные)
SELECT (SELECT SUM(amount) FROM l12_orders WHERE status = 'paid') AS amount_total,
       (SELECT SUM(i.quantity * i.unit_price)
          FROM l12_orders o
          JOIN l12_order_items i ON i.order_id = o.order_id AND i.order_date = o.order_date
         WHERE o.status = 'paid') AS items_total;

-- 5. Новая секция январь 2026
CREATE TABLE IF NOT EXISTS l12_orders_2026_01
PARTITION OF l12_orders
FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

BEGIN;
INSERT INTO l12_orders (order_id, order_date, customer_id, status, amount)
VALUES (1299999, '2026-01-15', 1200001, 'new', 950);
-- Строка в секции l12_orders_2026_01
SELECT tableoid::regclass, order_id, order_date FROM l12_orders WHERE order_id = 1299999;
ROLLBACK;

-- 6. Ошибка маршрутизации: нет секции на февраль 2026
BEGIN;
INSERT INTO l12_orders VALUES (1299998, '2026-02-10', 1200001, 'new', 100);
-- ERROR: no partition of relation "l12_orders" found for row
-- Нет подходящей секции и нет DEFAULT. Решение: заранее создавать секции на будущие месяцы
ROLLBACK;

-- Вывод
-- Секционирование помогает, когда запрос фильтрует по ключу: читается одна секция вместо 12.
-- Без фильтра по ключу (или с функцией над ним) читаются все секции.
-- Издержки: составной ключ, секции нужно создавать заранее. На 2400 строках разница по времени
-- мала, главное доказательство число секций и Buffers.
