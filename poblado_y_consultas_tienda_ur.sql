-- ============================================================================
--  SCRIPT DE POBLADO Y CONSULTAS - Tienda UR
--  Genera datos transaccionales y demuestra consultas analíticas
--  Base: tienda_ur  |  Requisitos previos: categoria(8), cliente(100), producto(150)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- LIMPIEZA: vacía las 4 tablas transaccionales antes de regenerar.
--   RESTART IDENTITY -> reinicia los contadores SERIAL (los IDs vuelven a 1).
--   CASCADE          -> permite truncar aunque haya dependencias por FK.
--   Se listan en orden hijo->padre; el CASCADE arrastra el resto.
-- Resultado esperado: TRUNCATE TABLE (las 4 quedan en 0 filas).
-- ----------------------------------------------------------------------------
TRUNCATE pago, envio, detalle_pedido, pedido RESTART IDENTITY CASCADE;

-- ----------------------------------------------------------------------------
-- 1) PEDIDOS: crea 300 pedidos con datos aleatorios.
--   cliente_id  -> entero 1..100 (un cliente existente al azar).
--   fecha_pedido-> ahora menos 0..180 días (pedidos repartidos en ~6 meses).
--   estado      -> uno de los 4 valores válidos, elegido por índice aleatorio.
--   generate_series(1,300) -> genera 300 filas "en blanco" que alimentan el SELECT.
-- Resultado esperado: INSERT 0 300.
-- ----------------------------------------------------------------------------
INSERT INTO pedido (cliente_id, fecha_pedido, estado)
SELECT (1+floor(random()*100))::int,                                  -- cliente al azar
       now() - ((random()*180)::int || ' days')::interval,            -- fecha en el pasado
       (ARRAY['carrito','confirmado','completado','cancelado'])[1+floor(random()*4)]  -- estado al azar
FROM generate_series(1,300);

-- ----------------------------------------------------------------------------
-- 2) DETALLE: asigna de 1 a 5 productos DISTINTOS a cada pedido.
--   Subconsulta interna:
--     ped -> a cada pedido le fija un n_items aleatorio (1..5).
--     CROSS JOIN producto -> empareja cada pedido con TODOS los productos.
--     row_number() ... PARTITION BY pedido ORDER BY random() -> baraja los
--        productos dentro de cada pedido y les pone un número de fila (rn).
--   WHERE rn <= n_items -> se queda solo con los primeros n_items de cada
--        pedido, garantizando productos únicos (sin violar la PK compuesta).
--   precio_unitario = precio actual del producto (precio histórico de la compra).
--   cantidad -> 1..5 unidades por línea.
-- Resultado esperado: INSERT 0 ~900 (varía por el azar; p. ej. 923).
-- ----------------------------------------------------------------------------
INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
SELECT pedido_id, producto_id, (1+floor(random()*5))::int, precio
FROM (
  SELECT ped.pedido_id, ped.n_items, pr.producto_id, pr.precio,
         row_number() OVER (PARTITION BY ped.pedido_id ORDER BY random()) rn  -- baraja por pedido
  FROM (SELECT pedido_id, (1+floor(random()*5))::int n_items FROM pedido) ped -- nº de ítems por pedido
  CROSS JOIN producto pr                                                      -- todos los productos
) r
WHERE rn <= n_items;   -- toma solo los primeros n_items de cada pedido

-- ----------------------------------------------------------------------------
-- 3) ENVÍO: crea exactamente un envío por pedido (relación 1:1).
--   direccion_entrega -> dirección ficticia de campus (Bloque 1..12).
--   costo_envio       -> uno de los 4 valores predefinidos (incluye 0 = gratis).
--   estado_envio      -> uno de los 4 estados válidos, al azar.
--   fecha_estimada    -> fecha del pedido + 3 días.
--   fecha_entrega     -> 50% de los envíos ya entregados (fecha+4d), 50% NULL.
--   La unicidad 1:1 la garantiza el UNIQUE de envio.pedido_id en el DDL.
-- Resultado esperado: INSERT 0 300.
-- ----------------------------------------------------------------------------
INSERT INTO envio (pedido_id, direccion_entrega, costo_envio, estado_envio, fecha_estimada, fecha_entrega)
SELECT p.pedido_id,
       'Bloque '||(1+floor(random()*12))::int||' - Campus UR',              -- dirección de campus
       (ARRAY[0,3000,5000,8000])[1+floor(random()*4)],                     -- costo de envío
       (ARRAY['preparando','despachado','en_transito','entregado'])[1+floor(random()*4)],  -- estado
       (p.fecha_pedido + interval '3 day')::date,                          -- fecha estimada
       CASE WHEN random()<0.5 THEN p.fecha_pedido + interval '4 day' ELSE NULL END  -- entregado o no
FROM pedido p;

-- ----------------------------------------------------------------------------
-- 4) PAGO: crea un pago por pedido (relación 1:1).
--   metodo      -> uno de los 4 métodos válidos, al azar.
--   monto       -> subtotal de las líneas + costo de envío.
--                  COALESCE protege contra NULL (pedido sin líneas o sin envío).
--   estado_pago -> uno de los 4 estados válidos, al azar.
--   fecha_pago  -> 70% pagados (fecha+1h), 30% NULL (aún sin pagar).
--   LEFT JOIN a la suma de detalle -> obtiene el subtotal por pedido.
--   LEFT JOIN a envio             -> obtiene el costo de envío por pedido.
--   Va de último porque DEPENDE de que detalle y envio ya existan.
-- Resultado esperado: INSERT 0 300.
-- ----------------------------------------------------------------------------
INSERT INTO pago (pedido_id, metodo, monto, estado_pago, fecha_pago)
SELECT p.pedido_id,
       (ARRAY['tarjeta','pse','efectivo','transferencia'])[1+floor(random()*4)],  -- método de pago
       COALESCE(t.subtotal,0) + COALESCE(e.costo_envio,0),                         -- monto total cobrado
       (ARRAY['pendiente','aprobado','rechazado','reembolsado'])[1+floor(random()*4)],  -- estado del pago
       CASE WHEN random()<0.7 THEN p.fecha_pedido + interval '1 hour' ELSE NULL END      -- fecha de pago
FROM pedido p
LEFT JOIN (SELECT pedido_id, SUM(cantidad*precio_unitario) subtotal   -- subtotal de líneas por pedido
           FROM detalle_pedido GROUP BY pedido_id) t ON t.pedido_id=p.pedido_id
LEFT JOIN envio e ON e.pedido_id=p.pedido_id;                          -- costo de envío por pedido

-- ----------------------------------------------------------------------------
-- VERIFICACIÓN DE CONTEOS: confirma cuántas filas quedó cada tabla.
-- Resultado esperado: pedido 300, detalle ~900, pago 300, envio 300.
-- ----------------------------------------------------------------------------
SELECT 'pedido' t, count(*) FROM pedido
UNION ALL SELECT 'detalle', count(*) FROM detalle_pedido
UNION ALL SELECT 'pago', count(*) FROM pago
UNION ALL SELECT 'envio', count(*) FROM envio;

-- ============================================================================
--  CONSULTAS ANALÍTICAS DE EJEMPLO
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONSULTA A: total de cada pedido.
--   El "total" NO está almacenado en ninguna columna: se calcula con SUM().
--   Esto es la 3FN en acción -> no se guarda lo que se puede derivar.
--   Une pedido con cliente, detalle, envio y pago (4 JOIN).
--   GROUP BY colapsa las varias líneas de detalle en un total por pedido.
--   Muestra los 10 pedidos de mayor valor.
-- ----------------------------------------------------------------------------
SELECT p.pedido_id, c.nombres, c.apellidos,
       SUM(d.cantidad * d.precio_unitario) AS total_productos,  -- subtotal derivado
       e.costo_envio,
       pg.monto AS total_pagado                                 -- debe = total_productos + costo_envio
FROM pedido p
JOIN cliente c        ON c.cliente_id = p.cliente_id
JOIN detalle_pedido d ON d.pedido_id  = p.pedido_id
JOIN envio e          ON e.pedido_id  = p.pedido_id
JOIN pago  pg         ON pg.pedido_id = p.pedido_id
GROUP BY p.pedido_id, c.nombres, c.apellidos, e.costo_envio, pg.monto
ORDER BY total_pagado DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- CONSULTA B: productos más vendidos por unidades.
--   Une detalle con producto para recuperar el nombre.
--   SUM(cantidad) agrupa por producto -> total de unidades vendidas.
--   Top 10 descendente.
-- ----------------------------------------------------------------------------
SELECT pr.nombre, SUM(d.cantidad) AS unidades_vendidas
FROM detalle_pedido d
JOIN producto pr ON pr.producto_id = d.producto_id
GROUP BY pr.nombre
ORDER BY unidades_vendidas DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- CONSULTA C: ingresos por categoría.
--   JOIN de 3 tablas: detalle -> producto -> categoria.
--   SUM(cantidad * precio_unitario) agrupado por nombre de categoría.
--   Muestra qué categorías generan más ingresos.
-- ----------------------------------------------------------------------------
SELECT c.nombre AS categoria, SUM(d.cantidad * d.precio_unitario) AS ingresos
FROM detalle_pedido d
JOIN producto pr  ON pr.producto_id = d.producto_id
JOIN categoria c  ON c.categoria_id = pr.categoria_id
GROUP BY c.nombre
ORDER BY ingresos DESC;
