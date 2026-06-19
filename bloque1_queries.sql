-- ============================================================================
-- Bloque 1 — SQL Avanzado
-- Prueba Técnica · Data Analyst · Cadena de Retail Multiformato · Centroamérica
-- Dialecto: BigQuery Standard SQL
-- Tablas asumidas en dataset `retail`:
--   retail.transactions, retail.transaction_items,
--   retail.stores, retail.products, retail.vendors, retail.store_promotions
-- ============================================================================


-- ============================================================================
-- QUERY 1: Ventas Comparables (Comp Sales) — Crecimiento YoY
-- ============================================================================
-- Métrica estándar de retail. Solo tiendas que estuvieron operando en AMBOS
-- períodos. Se excluyen tiendas abiertas hace menos de 13 meses desde la
-- fecha de corte (junio 2025).
--
-- Períodos comparados:
--   "Año actual"   = H1 2025: 01/01/2025 – 30/06/2025
--   "Año anterior" = H1 2024: 01/01/2024 – 30/06/2024
-- ============================================================================

WITH

-- Parámetros globales del análisis
-- fecha_corte = último día con datos en el dataset (equivalente a CURRENT_DATE - 1 DAY
-- en producción). Esto hace el script autocontenido sin hardcodear fechas.
params AS (
  SELECT
    MAX(t.transaction_date)                                                    AS fecha_corte,
    -- TY: desde el 1 de enero del año del último dato hasta ese día
    DATE_TRUNC(MAX(t.transaction_date), YEAR)                                  AS inicio_actual,
    MAX(t.transaction_date)                                                    AS fin_actual,
    -- LY: mismo período del año anterior (Jan 1 LY → último día del mes actual LY)
    DATE_SUB(DATE_TRUNC(MAX(t.transaction_date), YEAR), INTERVAL 1 YEAR)       AS inicio_anterior,
    DATE_SUB(
      DATE_SUB(
        DATE_ADD(DATE_TRUNC(MAX(t.transaction_date), MONTH), INTERVAL 1 MONTH),
        INTERVAL 1 DAY
      ),
      INTERVAL 1 YEAR
    )                                                                          AS fin_anterior
  FROM `retail.transactions` t
  WHERE t.status = 'COMPLETED'
),

-- Tiendas elegibles para Comp Sales:
-- Deben haber abierto ≥13 meses antes de la fecha de corte
-- = abierta antes del 31/05/2024 (tienen historia en ambos H1)
tiendas_comp AS (
  SELECT
    s.store_id,
    s.store_name,
    s.country,
    s.format,
    s.opening_date
  FROM `retail.stores` s
  CROSS JOIN params p
  WHERE s.opening_date <= DATE_SUB(p.fecha_corte, INTERVAL 13 MONTH)
),

-- GMV por tienda en cada período (solo transacciones COMPLETED con monto válido)
gmv_por_periodo AS (
  SELECT
    t.store_id,
    SUM(CASE
      WHEN t.transaction_date BETWEEN p.inicio_actual AND p.fin_actual
      THEN t.total_amount ELSE 0 END)  AS gmv_actual,
    SUM(CASE
      WHEN t.transaction_date BETWEEN p.inicio_anterior AND p.fin_anterior
      THEN t.total_amount ELSE 0 END)  AS gmv_anterior
  FROM `retail.transactions` t
  CROSS JOIN params p
  WHERE t.status = 'COMPLETED'
    AND t.total_amount > 0
  GROUP BY t.store_id
),

-- Unir tiendas elegibles con sus GMV en cada período
comp_sales_base AS (
  SELECT
    tc.store_id,
    tc.store_name,
    tc.country,
    tc.format,
    g.gmv_actual,
    g.gmv_anterior,
    -- Crecimiento YoY — SAFE_DIVIDE evita división por cero
    SAFE_DIVIDE(g.gmv_actual - g.gmv_anterior, g.gmv_anterior) * 100 AS comp_growth_pct
  FROM tiendas_comp tc
  INNER JOIN gmv_por_periodo g USING (store_id)
  -- Solo tiendas con ventas reales en ambos períodos (excluye cierres temporales)
  WHERE g.gmv_anterior > 0 AND g.gmv_actual > 0
),

-- Benchmark por país-formato para contexto del ranking
benchmark AS (
  SELECT
    country,
    format,
    COUNT(store_id)                    AS n_tiendas_comp,
    SUM(gmv_actual)                    AS gmv_actual_total,
    SUM(gmv_anterior)                  AS gmv_anterior_total,
    SAFE_DIVIDE(
      SUM(gmv_actual) - SUM(gmv_anterior),
      SUM(gmv_anterior)
    ) * 100                            AS comp_growth_formato_pct
  FROM comp_sales_base
  GROUP BY country, format
),

-- Ranking de cada tienda dentro de su formato
tiendas_ranked AS (
  SELECT
    store_id,
    store_name,
    country,
    format,
    gmv_actual,
    gmv_anterior,
    comp_growth_pct,
    -- Ranking dentro del mismo país y formato: granularidad consistente
    ROW_NUMBER() OVER (
      PARTITION BY format, country
      ORDER BY comp_growth_pct DESC
    ) AS rank_crecimiento_en_formato
  FROM comp_sales_base
)

-- Resultado final: columnas de tienda + benchmark del formato
SELECT
  r.country,
  r.format,
  r.store_id,
  r.store_name,
  ROUND(r.gmv_anterior, 2)             AS gmv_h1_2024,
  ROUND(r.gmv_actual, 2)               AS gmv_h1_2025,
  ROUND(r.comp_growth_pct, 2)          AS comp_growth_pct,
  r.rank_crecimiento_en_formato,
  b.n_tiendas_comp,
  ROUND(b.comp_growth_formato_pct, 2)  AS comp_growth_formato_pct,
  ROUND(b.gmv_actual_total, 2)         AS gmv_formato_total_2025
FROM tiendas_ranked r
LEFT JOIN benchmark b ON r.country = b.country AND r.format = b.format
ORDER BY r.format, r.rank_crecimiento_en_formato;


-- ============================================================================
-- QUERY 2: Productividad por Metro Cuadrado
-- ============================================================================
-- "Último trimestre" = Q2 2025 (abril – junio 2025)
-- KPIs: GMV/m², transacciones/m², ticket promedio, ranking en formato
-- Alerta: BAJO_RENDIMIENTO = por debajo del percentil 25 de GMV/m² en formato
-- ============================================================================

WITH

-- Último trimestre completo dinámico:
--   inicio = primer día del trimestre anterior al trimestre en curso
--   fin    = último día de ese trimestre (= primer día del trimestre actual - 1 día)
tx_q AS (
  SELECT
    t.store_id,
    COUNT(DISTINCT t.transaction_id)  AS n_transacciones,
    SUM(t.total_amount)               AS gmv_total,
    AVG(t.total_amount)               AS ticket_promedio
  FROM `retail.transactions` t
  CROSS JOIN (
    SELECT
      DATE_TRUNC(
        DATE_SUB(DATE_TRUNC(MAX(transaction_date), MONTH), INTERVAL 3 MONTH),
        QUARTER
      )                                                                     AS inicio_trimestre,
      DATE_SUB(DATE_TRUNC(MAX(transaction_date), QUARTER), INTERVAL 1 DAY) AS fin_trimestre
    FROM `retail.transactions`
    WHERE status = 'COMPLETED'
  ) q
  WHERE t.status = 'COMPLETED'
    AND t.total_amount > 0
    AND t.transaction_date BETWEEN q.inicio_trimestre AND q.fin_trimestre
  GROUP BY t.store_id
),

-- KPIs de productividad por tienda
store_productividad AS (
  SELECT
    s.store_id,
    s.store_name,
    s.country,
    s.format,
    s.region,
    s.size_sqm,
    COALESCE(tx.gmv_total, 0)                               AS gmv_q2,
    COALESCE(tx.n_transacciones, 0)                         AS n_transacciones,
    COALESCE(tx.ticket_promedio, 0)                         AS ticket_promedio,
    SAFE_DIVIDE(tx.gmv_total, s.size_sqm)                   AS gmv_por_m2,
    SAFE_DIVIDE(tx.n_transacciones, s.size_sqm)             AS tx_por_m2
  FROM `retail.stores` s
  LEFT JOIN tx_q tx USING (store_id)
),

-- Percentil 25 de GMV/m² dentro de cada formato
percentil_25 AS (
  SELECT DISTINCT
    format,
    PERCENTILE_CONT(gmv_por_m2, 0.25) OVER (PARTITION BY format) AS p25_gmv_m2
  FROM store_productividad
),

-- Ranking y clasificación
store_ranked AS (
  SELECT
    sp.*,
    pf.p25_gmv_m2,
    ROW_NUMBER() OVER (
      PARTITION BY sp.format
      ORDER BY sp.gmv_por_m2 DESC
    ) AS rank_gmv_m2_formato,
    -- Percentil absoluto dentro del formato (0=menor, 1=mayor)
    PERCENT_RANK() OVER (
      PARTITION BY sp.format
      ORDER BY sp.gmv_por_m2 ASC
    ) AS percentil_ascendente
  FROM store_productividad sp
  LEFT JOIN percentil_25 pf USING (format)
)

SELECT
  store_id,
  store_name,
  country,
  format,
  region,
  size_sqm,
  ROUND(gmv_q2, 2)                          AS gmv_q2_2025,
  ROUND(gmv_por_m2, 2)                      AS gmv_por_m2,
  ROUND(tx_por_m2, 4)                       AS transacciones_por_m2,
  ROUND(ticket_promedio, 2)                 AS ticket_promedio,
  rank_gmv_m2_formato,
  ROUND(percentil_ascendente * 100, 1)      AS percentil_en_formato,
  CASE
    WHEN gmv_por_m2 < p25_gmv_m2 THEN 'BAJO_RENDIMIENTO'
    ELSE 'NORMAL'
  END                                       AS clasificacion
FROM store_ranked
ORDER BY format, rank_gmv_m2_formato;


-- ============================================================================
-- QUERY 3: Análisis de Cohortes de Clientes con Tarjeta de Lealtad
-- ============================================================================
-- Cohorte = mes de la primera transacción del cliente (loyalty_card = TRUE)
-- Retención mes N = % de clientes de la cohorte que compraron en el mes N
-- ============================================================================

WITH

-- Primera transacción por cliente (define la cohorte)
primera_compra AS (
  SELECT
    customer_id,
    DATE_TRUNC(MIN(transaction_date), MONTH) AS cohorte_mes
  FROM `retail.transactions`
  WHERE loyalty_card = TRUE
    AND customer_id IS NOT NULL
    AND status = 'COMPLETED'
  GROUP BY customer_id
),

-- Actividad mensual por cliente
actividad_mensual AS (
  SELECT
    t.customer_id,
    DATE_TRUNC(t.transaction_date, MONTH) AS mes_actividad,
    AVG(t.total_amount)                   AS ticket_promedio_mes
  FROM `retail.transactions` t
  WHERE t.loyalty_card = TRUE
    AND t.customer_id IS NOT NULL
    AND t.status = 'COMPLETED'
  GROUP BY t.customer_id, DATE_TRUNC(t.transaction_date, MONTH)
),

-- Mes relativo respecto a la cohorte
cohorte_actividad AS (
  SELECT
    pc.cohorte_mes,
    am.customer_id,
    am.mes_actividad,
    am.ticket_promedio_mes,
    DATE_DIFF(am.mes_actividad, pc.cohorte_mes, MONTH) AS mes_relativo
  FROM primera_compra pc
  INNER JOIN actividad_mensual am USING (customer_id)
),

-- Tamaño de cada cohorte (clientes únicos en mes 0)
tamano_cohorte AS (
  SELECT
    cohorte_mes,
    COUNT(DISTINCT customer_id) AS n_clientes
  FROM cohorte_actividad
  WHERE mes_relativo = 0
  GROUP BY cohorte_mes
),

-- Retención y ticket por cohorte y mes relativo
retencion AS (
  SELECT
    ca.cohorte_mes,
    ca.mes_relativo,
    COUNT(DISTINCT ca.customer_id) AS activos,
    AVG(ca.ticket_promedio_mes)    AS ticket_promedio
  FROM cohorte_actividad ca
  WHERE ca.mes_relativo BETWEEN 0 AND 12
  GROUP BY ca.cohorte_mes, ca.mes_relativo
),

-- Unir con tamaño para calcular % de retención
retencion_pct AS (
  SELECT
    r.cohorte_mes,
    r.mes_relativo,
    r.activos,
    tc.n_clientes,
    SAFE_DIVIDE(r.activos, tc.n_clientes) * 100 AS tasa_retencion_pct,
    ROUND(r.ticket_promedio, 2)                 AS ticket_promedio
  FROM retencion r
  INNER JOIN tamano_cohorte tc USING (cohorte_mes)
)

-- Tabla pivoteada: meses clave como columnas
SELECT
  FORMAT_DATE('%Y-%m', cohorte_mes)                                   AS cohorte,
  MAX(n_clientes)                                                     AS tamano_cohorte,
  -- Retención (%)
  MAX(CASE WHEN mes_relativo = 0 THEN ROUND(tasa_retencion_pct,1) END) AS ret_mes_0_pct,
  MAX(CASE WHEN mes_relativo = 1 THEN ROUND(tasa_retencion_pct,1) END) AS ret_mes_1_pct,
  MAX(CASE WHEN mes_relativo = 2 THEN ROUND(tasa_retencion_pct,1) END) AS ret_mes_2_pct,
  MAX(CASE WHEN mes_relativo = 3 THEN ROUND(tasa_retencion_pct,1) END) AS ret_mes_3_pct,
  MAX(CASE WHEN mes_relativo = 6 THEN ROUND(tasa_retencion_pct,1) END) AS ret_mes_6_pct,
  -- Ticket promedio (para evaluar si crece con el tiempo)
  MAX(CASE WHEN mes_relativo = 0 THEN ticket_promedio END)            AS ticket_mes_0,
  MAX(CASE WHEN mes_relativo = 1 THEN ticket_promedio END)            AS ticket_mes_1,
  MAX(CASE WHEN mes_relativo = 2 THEN ticket_promedio END)            AS ticket_mes_2,
  MAX(CASE WHEN mes_relativo = 3 THEN ticket_promedio END)            AS ticket_mes_3,
  MAX(CASE WHEN mes_relativo = 6 THEN ticket_promedio END)            AS ticket_mes_6
FROM retencion_pct
GROUP BY cohorte_mes
ORDER BY cohorte_mes;


-- ============================================================================
-- QUERY 4: GMROI por Proveedor y Categoría
-- ============================================================================
-- GMROI = Margen Bruto / Costo Total
-- Margen Bruto = SUM(quantity * unit_price) - SUM(quantity * cost)
-- Alerta: GMROI < 1 → el proveedor genera menos margen del que cuesta
-- ============================================================================

WITH

-- Días del período analizado: desde el primer día del año anterior hasta fecha_corte
periodo AS (
  SELECT
    DATE_DIFF(
      MAX(transaction_date),
      DATE_SUB(DATE_TRUNC(MAX(transaction_date), YEAR), INTERVAL 1 YEAR),
      DAY
    ) + 1 AS n_dias
  FROM `retail.transactions`
  WHERE status = 'COMPLETED'
),

-- Ventas con costo del producto (excluir precios y costos inválidos — hallazgo B0)
ventas_detalle AS (
  SELECT
    ti.item_id,
    ti.quantity,
    ti.quantity * ti.unit_price   AS revenue_linea,
    ti.quantity * p.cost          AS costo_linea,
    p.vendor_id,
    p.category
  FROM `retail.transaction_items` ti
  INNER JOIN `retail.products` p USING (item_id)
  INNER JOIN `retail.transactions` t USING (transaction_id)
  WHERE t.status = 'COMPLETED'
    AND t.total_amount > 0
    AND ti.unit_price > 0   -- excluir unit_price = 0 sin promo (hallazgo B0)
    AND p.cost > 0           -- excluir costos inválidos (hallazgo B0)
),

-- Agregar por vendor + categoría
gmroi_base AS (
  SELECT
    vd.vendor_id,
    v.vendor_name,
    v.tier                                              AS vendor_tier,
    vd.category,
    COUNT(DISTINCT vd.item_id)                          AS skus_activos,
    SUM(vd.quantity)                                    AS unidades_vendidas,
    ROUND(SUM(vd.revenue_linea), 2)                     AS gmv,
    ROUND(SUM(vd.costo_linea), 2)                       AS costo_total,
    ROUND(SUM(vd.revenue_linea) - SUM(vd.costo_linea), 2) AS margen_bruto
  FROM ventas_detalle vd
  INNER JOIN `retail.vendors` v USING (vendor_id)
  GROUP BY vd.vendor_id, v.vendor_name, v.tier, vd.category
)

SELECT
  vendor_id,
  vendor_name,
  vendor_tier,
  category,
  skus_activos,
  unidades_vendidas,
  gmv,
  costo_total,
  margen_bruto,
  ROUND(SAFE_DIVIDE(margen_bruto, costo_total), 4)           AS gmroi,
  ROUND(SAFE_DIVIDE(margen_bruto, gmv) * 100, 2)             AS margen_pct,
  -- Velocidad de venta: unidades por día en el período completo
  ROUND(SAFE_DIVIDE(unidades_vendidas,
    (SELECT n_dias FROM periodo)), 2)                          AS unidades_por_dia,
  -- Clasificación de riesgo
  CASE
    WHEN SAFE_DIVIDE(margen_bruto, costo_total) < 1   THEN 'GMROI_CRITICO'   -- genera menos margen que costo
    WHEN SAFE_DIVIDE(margen_bruto, costo_total) < 1.5 THEN 'GMROI_BAJO'
    WHEN SAFE_DIVIDE(margen_bruto, costo_total) < 2.5 THEN 'GMROI_NORMAL'
    ELSE                                                   'GMROI_ALTO'
  END AS clasificacion_gmroi
FROM gmroi_base
ORDER BY gmroi ASC;  -- peores primero para facilitar acción comercial


-- ============================================================================
-- QUERY 5: Detección de Posibles Quiebres de Stock
-- ============================================================================
-- Definición: brecha ≥3 días sin ventas en una tienda donde el ítem
-- históricamente sí se vendía (≥7 días de ventas en el pasado).
--
-- Técnica: gap-and-island sobre espina de fechas generada con
-- GENERATE_DATE_ARRAY + UNNEST.
-- GMV perdido estimado = avg_revenue_diario × días_de_quiebre
-- ============================================================================

WITH

-- Ventas diarias por tienda-ítem (transacciones válidas)
ventas_diarias AS (
  SELECT
    t.store_id,
    ti.item_id,
    t.transaction_date,
    SUM(ti.quantity * ti.unit_price)  AS revenue_dia,
    SUM(ti.quantity)                  AS unidades_dia
  FROM `retail.transaction_items` ti
  INNER JOIN `retail.transactions` t USING (transaction_id)
  WHERE t.status = 'COMPLETED'
    AND t.total_amount > 0
    AND ti.unit_price > 0
  GROUP BY t.store_id, ti.item_id, t.transaction_date
),

-- Pares (tienda, ítem) con historia suficiente (≥7 días de ventas)
pares_activos AS (
  SELECT
    store_id,
    item_id,
    MIN(transaction_date)         AS primera_venta,
    MAX(transaction_date)         AS ultima_venta,
    COUNT(transaction_date)       AS dias_con_venta,
    AVG(revenue_dia)              AS avg_revenue_dia,
    AVG(unidades_dia)             AS avg_unidades_dia
  FROM ventas_diarias
  GROUP BY store_id, item_id
  HAVING COUNT(transaction_date) >= 7
),

-- Espina de fechas completa por par activo (cada día entre primera y última venta)
fecha_espina AS (
  SELECT
    pa.store_id,
    pa.item_id,
    pa.avg_revenue_dia,
    fecha_gen
  FROM pares_activos pa,
  UNNEST(GENERATE_DATE_ARRAY(pa.primera_venta, pa.ultima_venta)) AS fecha_gen
),

-- Marcar días sin venta (gaps)
dias_gap AS (
  SELECT
    fe.store_id,
    fe.item_id,
    fe.fecha_gen        AS fecha,
    fe.avg_revenue_dia,
    CASE WHEN vd.transaction_date IS NULL THEN 1 ELSE 0 END AS es_gap
  FROM fecha_espina fe
  LEFT JOIN ventas_diarias vd
    ON fe.store_id = vd.store_id
   AND fe.item_id  = vd.item_id
   AND fe.fecha_gen = vd.transaction_date
),

-- Gap-and-island: asignar ID de grupo a secuencias de días gap consecutivos
-- Técnica clásica: rank global - rank dentro del grupo → constante en secuencias
gap_island AS (
  SELECT
    store_id,
    item_id,
    fecha,
    avg_revenue_dia,
    -- El "group_id" cambia cada vez que se rompe la secuencia
    DATE_DIFF(fecha, DATE '2024-01-01', DAY)
      - ROW_NUMBER() OVER (
          PARTITION BY store_id, item_id
          ORDER BY fecha
        )                                   AS island_id
  FROM dias_gap
  WHERE es_gap = 1
),

-- Agregar por grupo de gap consecutivo
gaps_agregados AS (
  SELECT
    store_id,
    item_id,
    MIN(fecha)                             AS fecha_inicio_gap,
    MAX(fecha)                             AS fecha_fin_gap,
    COUNT(*)                               AS duracion_dias,
    MAX(avg_revenue_dia)                   AS avg_revenue_dia
  FROM gap_island
  GROUP BY store_id, item_id, island_id
  HAVING COUNT(*) >= 3  -- solo quiebres de 3+ días
)

-- Resultado enriquecido con dimensiones
SELECT
  ga.store_id,
  s.store_name,
  s.country,
  s.format,
  ga.item_id,
  p.item_name,
  p.category,
  p.vendor_id,
  v.vendor_name,
  ga.fecha_inicio_gap,
  ga.fecha_fin_gap,
  ga.duracion_dias,
  ROUND(ga.avg_revenue_dia, 2)                             AS avg_gmv_diario_previo,
  -- GMV perdido estimado = días_sin_venta × promedio_diario_histórico
  ROUND(ga.avg_revenue_dia * ga.duracion_dias, 2)          AS gmv_perdido_estimado
FROM gaps_agregados ga
INNER JOIN `retail.stores`   s USING (store_id)
INNER JOIN `retail.products` p USING (item_id)
INNER JOIN `retail.vendors`  v ON p.vendor_id = v.vendor_id
ORDER BY gmv_perdido_estimado DESC;


-- ============================================================================
-- QUERY 6: Impacto de Promociones en Ticket y Volumen (Basket Analysis)
-- ============================================================================
-- Compara por categoría el ticket promedio y las unidades promedio en
-- transacciones CON y SIN ítems en promo.
-- Interpretación:
--   BASKET_UPLIFT_REAL        → ticket Y unidades suben con promo
--   SOLO_EFECTO_PRECIO        → solo ticket sube (sin más volumen)
--   VOLUMEN_SIN_TICKET_EXTRA  → más unidades pero mismo ticket
--   SIN_EFECTO_CLARO          → no hay diferencia estadística visible
-- ============================================================================

WITH

-- Clasificar cada transacción: ¿tiene al menos 1 ítem en promo?
tx_clasif AS (
  SELECT
    transaction_id,
    MAX(CASE WHEN was_on_promo = TRUE THEN 1 ELSE 0 END) AS tiene_promo,
    SUM(quantity)                                         AS unidades_totales,
    COUNT(transaction_item_id)                            AS n_items
  FROM `retail.transaction_items`
  GROUP BY transaction_id
),

-- Header de transacción (solo completadas con monto válido)
tx_full AS (
  SELECT
    t.transaction_id,
    t.total_amount,
    tc.tiene_promo,
    tc.unidades_totales
  FROM `retail.transactions` t
  INNER JOIN tx_clasif tc USING (transaction_id)
  WHERE t.status = 'COMPLETED'
    AND t.total_amount > 0
),

-- Revenue y unidades por transacción-categoría
tx_categoria AS (
  SELECT
    tf.transaction_id,
    tf.total_amount        AS ticket_total_tx,
    tf.unidades_totales,
    tf.tiene_promo,
    p.category,
    SUM(ti.quantity * ti.unit_price) AS revenue_cat,
    SUM(ti.quantity)                 AS unidades_cat,
    -- ¿Hay ítems de esta categoría específica en promo?
    MAX(CASE WHEN ti.was_on_promo = TRUE THEN 1 ELSE 0 END) AS hay_promo_cat
  FROM tx_full tf
  INNER JOIN `retail.transaction_items` ti USING (transaction_id)
  INNER JOIN `retail.products` p ON ti.item_id = p.item_id
  GROUP BY tf.transaction_id, tf.total_amount, tf.unidades_totales, tf.tiene_promo, p.category
),

-- Agregar por categoría × tipo de transacción
resumen AS (
  SELECT
    category,
    hay_promo_cat                      AS con_promo,
    COUNT(DISTINCT transaction_id)     AS n_transacciones,
    AVG(ticket_total_tx)               AS avg_ticket,
    AVG(unidades_totales)              AS avg_unidades,
    AVG(revenue_cat)                   AS avg_revenue_categoria
  FROM tx_categoria
  GROUP BY category, hay_promo_cat
)

-- Pivotear: una fila por categoría, columnas con/sin promo
SELECT
  category,
  MAX(CASE WHEN con_promo=0 THEN n_transacciones END)           AS n_tx_sin_promo,
  MAX(CASE WHEN con_promo=1 THEN n_transacciones END)           AS n_tx_con_promo,
  ROUND(MAX(CASE WHEN con_promo=0 THEN avg_ticket END), 2)      AS ticket_sin_promo,
  ROUND(MAX(CASE WHEN con_promo=1 THEN avg_ticket END), 2)      AS ticket_con_promo,
  ROUND(MAX(CASE WHEN con_promo=0 THEN avg_unidades END), 2)    AS unidades_sin_promo,
  ROUND(MAX(CASE WHEN con_promo=1 THEN avg_unidades END), 2)    AS unidades_con_promo,
  -- Uplift absoluto
  ROUND(
    MAX(CASE WHEN con_promo=1 THEN avg_ticket END)
    - MAX(CASE WHEN con_promo=0 THEN avg_ticket END),
  2) AS uplift_ticket_abs,
  -- Uplift relativo (%)
  ROUND(SAFE_DIVIDE(
    MAX(CASE WHEN con_promo=1 THEN avg_ticket END)
    - MAX(CASE WHEN con_promo=0 THEN avg_ticket END),
    MAX(CASE WHEN con_promo=0 THEN avg_ticket END)
  ) * 100, 2) AS uplift_ticket_pct,
  -- Uplift de unidades (%)
  ROUND(SAFE_DIVIDE(
    MAX(CASE WHEN con_promo=1 THEN avg_unidades END)
    - MAX(CASE WHEN con_promo=0 THEN avg_unidades END),
    MAX(CASE WHEN con_promo=0 THEN avg_unidades END)
  ) * 100, 2) AS uplift_unidades_pct,
  -- Interpretación de negocio
  CASE
    WHEN MAX(CASE WHEN con_promo=1 THEN avg_ticket END)
       > MAX(CASE WHEN con_promo=0 THEN avg_ticket END)
     AND MAX(CASE WHEN con_promo=1 THEN avg_unidades END)
       > MAX(CASE WHEN con_promo=0 THEN avg_unidades END)
    THEN 'BASKET_UPLIFT_REAL'
    WHEN MAX(CASE WHEN con_promo=1 THEN avg_ticket END)
       > MAX(CASE WHEN con_promo=0 THEN avg_ticket END)
    THEN 'SOLO_EFECTO_PRECIO'
    WHEN MAX(CASE WHEN con_promo=1 THEN avg_unidades END)
       > MAX(CASE WHEN con_promo=0 THEN avg_unidades END)
    THEN 'VOLUMEN_SIN_TICKET_EXTRA'
    ELSE 'SIN_EFECTO_CLARO'
  END AS interpretacion
FROM resumen
GROUP BY category
ORDER BY uplift_ticket_pct DESC;
