# Bloque 2 — Modelado de Datos + Diseño de Pipeline

**Prueba Técnica · Data Analyst · Cadena de Retail Multiformato · Centroamérica**

---

## Parte A — Modelo Dimensional (Star Schema)

### Resumen del modelo

El modelo sigue una arquitectura **dimensional en BigQuery**, con dos tablas de hechos de granularidad diferente y seis dimensiones conformadas. El núcleo es mayormente **Star Schema** — ambas facts se conectan directamente a la mayoría de las dimensiones — pero incluye dos normalizaciones puntuales que lo clasifican como **modelo híbrido con dimensiones outrigger**:

- `dim_product.vendor_key → dim_vendor`: un producto siempre pertenece a un proveedor; normalizarlo evita duplicar atributos del proveedor en cada producto.
- `dim_promotion.store_key → dim_store`: una promoción está asignada a una tienda específica por diseño del negocio.

Estas relaciones dimensión→dimensión son características de un **Snowflake Schema parcial**. La decisión de mantenerlas (en lugar de desnormalizar completamente) responde a que la relación producto-proveedor es estable y relevante para el análisis de GMROI, y BigQuery con columnar storage no penaliza el JOIN adicional.

```
                    ┌─────────────┐
                    │  dim_date   │
                    └──────┬──────┘
                           │
  ┌──────────────┐    ┌────┴───────────────┐    ┌───────────────┐
  │ dim_customer │────│ fact_transactions  │────│   dim_store   │
  └──────────────┘    └────────┬───────────┘    └───────────────┘
                               │ 1:N
                    ┌──────────┴───────────────┐
                    │  fact_transaction_items   │
                    └────────┬──────────────────┘
                             │
              ┌──────────────┼───────────────┐
         ┌────┴────┐    ┌────┴────┐    ┌─────┴──────┐
         │dim_prod │    │dim_vend │    │dim_promo   │
         └─────────┘    └─────────┘    └────────────┘
```

*(Ver bloque2_modelo.pdf para el diagrama con campos completos)*

---

### Tablas de Hechos

#### `fact_transactions`
Granularidad: **una fila = una transacción**.

| Campo | Tipo | Descripción |
|-------|------|-------------|
| transaction_key | INT64 | Surrogate key (PK) |
| transaction_id | STRING | ID original del source |
| transaction_date_key | INT64 | FK → dim_date |
| store_key | INT64 | FK → dim_store |
| customer_key | INT64 | FK → dim_customer (puede ser -1 = ANÓNIMO) |
| payment_method | STRING | CASH / CARD / DIGITAL |
| total_amount | FLOAT64 | Monto total reportado |
| status | STRING | COMPLETED / RETURNED |
| _source_loaded_at | TIMESTAMP | Timestamp de carga del pipeline |

#### `fact_transaction_items`
Granularidad: **una fila = una línea de ítem dentro de una transacción**.

| Campo | Tipo | Descripción |
|-------|------|-------------|
| transaction_item_key | INT64 | Surrogate key (PK) |
| transaction_item_id | STRING | ID original del source |
| transaction_key | INT64 | FK → fact_transactions |
| transaction_date_key | INT64 | FK → dim_date (desnormalizado para query eficiente) |
| store_key | INT64 | FK → dim_store (desnormalizado) |
| product_key | INT64 | FK → dim_product |
| quantity | INT64 | Unidades compradas |
| unit_price | FLOAT64 | Precio al momento de la venta |
| cost | FLOAT64 | Costo del producto (copiado de dim_product al momento de carga) |
| was_on_promo | BOOL | ¿Ítem en promoción? |
| revenue | FLOAT64 | quantity × unit_price (columna calculada / materializada) |
| gross_margin | FLOAT64 | revenue − (quantity × cost) |

---

### Tablas de Dimensiones

#### `dim_date`
Granularidad: **una fila = un día calendario**.

| Campo | Tipo |
|-------|------|
| date_key | INT64 (YYYYMMDD) |
| date | DATE |
| year | INT64 |
| quarter | INT64 |
| month | INT64 |
| month_name | STRING |
| week_iso | INT64 |
| day_of_week | INT64 |
| is_weekend | BOOL |
| is_holiday_cr / gt / hn / sv / ni | BOOL |

> Se pre-genera para el rango 2020–2030 y se actualiza una vez por año.

#### `dim_store` — *SCD Type 2*
Una tienda puede cambiar de tamaño o formato. Se versiona.

| Campo | Tipo |
|-------|------|
| store_key | INT64 (surrogate, PK) |
| store_id | STRING (natural key) |
| store_name | STRING |
| country | STRING |
| city | STRING |
| format | STRING |
| size_sqm | INT64 |
| region | STRING |
| opening_date | DATE |
| scd_start_date | DATE |
| scd_end_date | DATE |
| is_current | BOOL |

#### `dim_customer`
Incluye un registro especial para transacciones anónimas.

| Campo | Tipo |
|-------|------|
| customer_key | INT64 (surrogate, PK) |
| customer_id | STRING (puede ser NULL → key = -1) |
| is_anonymous | BOOL |
| loyalty_since | DATE |
| first_transaction_date | DATE |
| last_seen_date | DATE |

#### `dim_product`
| Campo | Tipo |
|-------|------|
| product_key | INT64 |
| item_id | STRING |
| item_name | STRING |
| brand | STRING |
| category | STRING |
| department | STRING |
| cost | FLOAT64 |
| vendor_key | INT64 |

#### `dim_vendor`
| Campo | Tipo |
|-------|------|
| vendor_key | INT64 |
| vendor_id | STRING |
| vendor_name | STRING |
| country | STRING |
| tier | STRING |
| is_shared_catalog | BOOL |

#### `dim_promotion`
| Campo | Tipo |
|-------|------|
| promotion_key | INT64 |
| promo_name | STRING |
| promo_type | STRING |
| variant | STRING |
| start_date | DATE |
| end_date | DATE |
| store_key | INT64 |

---

### Justificación de Decisiones de Diseño

#### Decisión 1: Dos tablas de hechos con granularidades diferentes

**Problema:** Los KPIs de negocio operan a niveles distintos:
- GMV total, retención y Comp Sales se calculan a nivel de **transacción**
- GMROI, Pareto de categorías y detección de quiebres requieren **línea de ítem**

**Decisión:** Mantener `fact_transactions` y `fact_transaction_items` como tablas separadas en lugar de una sola tabla "plana".

**Justificación:** Unir todo en una tabla plana multiplicaría el GMV (si una transacción tiene 5 ítems, `total_amount` aparecería 5 veces al hacer SUM). Las dos tablas se conectan vía `transaction_key` y respetan la granularidad correcta de cada análisis. BigQuery con columnar storage no penaliza el JOIN.

---

#### Decisión 2: Customer anónimo como registro especial en `dim_customer`

**Problema:** El 60% de las transacciones no tiene `customer_id` (clientes sin tarjeta de lealtad). Si dejamos `customer_key` como NULL en `fact_transactions`, las queries de retención y cohortes omitirían esas filas silenciosamente en algunos motores.

**Decisión:** Crear un registro fijo con `customer_key = -1`, `customer_id = NULL`, `is_anonymous = TRUE`.

**Justificación:**
1. Las transacciones anónimas se pueden agregar correctamente (conteo de tickets, GMV por tienda).
2. Los análisis de cohortes filtran explícitamente `is_anonymous = FALSE`, evitando confusión.
3. Facilita auditorías futuras: un COUNT de `customer_key = -1` da inmediatamente el volumen de tráfico no identificado.

---

#### Decisión 3: SCD Type 2 para `dim_store` (no SCD Type 1)

**Problema:** Una tienda puede renovarse y cambiar de `size_sqm` o de `format`. Con SCD Type 1 (sobrescribir), las métricas históricas de GMV/m² quedarían calculadas con el tamaño actual, distorsionando el comparativo YoY.

**Decisión:** Implementar SCD Type 2 con columnas `scd_start_date`, `scd_end_date` e `is_current`.

**Justificación:** El KPI central del programa (GMV/m²) es sensible al tamaño. Si una tienda amplió su superficie en julio 2024, los análisis de H1 2024 deben usar el tamaño vigente *en ese momento*. La cláusula `WHERE is_current = TRUE` simplifica queries que no necesitan historia, mientras que `JOIN dim_store ON store_key AND transaction_date BETWEEN scd_start_date AND scd_end_date` recupera la versión correcta.

---

#### Decisión 4 (bonus): `cost` se copia al momento de la transacción en `fact_transaction_items`

**Problema:** El costo de un producto puede cambiar con el tiempo (renegociación con proveedores). Si siempre referenciamos `dim_product.cost` al calcular el margen histórico, el GMROI de períodos anteriores quedaría distorsionado con costos actuales.

**Decisión:** El campo `cost` se copia (snapshot) en `fact_transaction_items` en el momento de la carga, de la misma manera que `unit_price` ya es un snapshot del precio al momento de la venta.

---

## Parte B — Diseño del Pipeline ETL/ELT

### Arquitectura general

```
[POS / Tiendas]
     │
     │ CSV / API cada hora
     ▼
[Cloud Storage / GCS]  ← zona de aterrizaje (raw)
     │
     │ Trigger por arrival o schedule
     ▼
[BigQuery — Capa RAW]  ← tablas particionadas por fecha de carga
     │
     │ dbt / Dataform
     ▼
[BigQuery — Capa STAGING]  ← limpieza, tipado, dedup
     │
     │ dbt / Dataform
     ▼
[BigQuery — Capa MARTS]  ← fact + dim + métricas pre-calculadas
     │
     ▼
[Dashboard / BI Tool]
```

---

### ¿Cómo manejar que las tiendas reportan con hasta 2 horas de retraso?

Las tiendas envían datos con hasta 2 horas de retraso. Si el pipeline corre a las 00:00 y carga transacciones del día anterior, las de las últimas 2 horas del día podrían faltar.

**Estrategia:**
1. El pipeline corre a las **02:30** (no a medianoche), garantizando que todas las transacciones del día anterior ya llegaron.
2. Las tablas RAW en BigQuery se particionan por `_source_loaded_at` (fecha de carga), no por `transaction_date`. Esto permite recargas parciales sin reescanear todo.
3. Se aplica una ventana de **lookback de 48 horas**: cada run también re-procesa los últimos 2 días de datos para capturar late arrivals.

---

### ¿Cómo detectar automáticamente que una tienda dejó de enviar datos?

**Monitor de actividad esperada:**
1. Para cada tienda, calcular el número esperado de transacciones diarias basado en los últimos 30 días (media móvil).
2. Si en las últimas 24h la tienda envió **menos del 20% de su media histórica**, generar alerta.
3. Implementar como una **query de monitoreo** que corre al final de cada pipeline y escribe resultados en una tabla `audit.store_activity_monitor`.
4. Si `n_transacciones_ayer / avg_ultimos_30_dias < 0.20` → alerta a Slack/PagerDuty.

```sql
-- Ejemplo de query de monitoreo (simplificado)
SELECT
  store_id,
  COUNT(*) AS tx_ayer,
  AVG(tx_diarias_historicas) AS avg_historico,
  COUNT(*) / AVG(tx_diarias_historicas) AS ratio_actividad,
  CASE WHEN COUNT(*) / AVG(tx_diarias_historicas) < 0.20
       THEN 'ALERTA: posible falla de reporte'
       ELSE 'OK' END AS estado
FROM ...
```

---

### ¿Cómo hacer cargas incrementales sin duplicar transacciones?

**Estrategia:** `MERGE` (upsert) en BigQuery basado en `transaction_id` como clave natural.

```sql
-- Pattern de carga incremental con MERGE
MERGE `retail.fact_transactions` T
USING (SELECT * FROM `retail_raw.transactions_staging` WHERE _loaded_date = CURRENT_DATE()) S
ON T.transaction_id = S.transaction_id
WHEN MATCHED THEN
  UPDATE SET status = S.status, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
  INSERT (transaction_id, transaction_date_key, store_key, ...)
  VALUES (S.transaction_id, ...)
```

**Notas:**
- `transaction_id` es la clave de deduplicación (validado en Bloque 0: 0 duplicados).
- El MATCHED branch actualiza el `status` porque una transacción `COMPLETED` puede volverse `RETURNED` después.
- En dbt, usar `incremental` con `unique_key = 'transaction_id'`.

---

### ¿Con qué frecuencia correría el pipeline si el dashboard necesita refresh diario?

**Configuración recomendada:**

| Job | Hora | Descripción |
|-----|------|-------------|
| Ingesta RAW | 02:30 | Carga archivos del día anterior desde GCS |
| Staging | 03:00 | Limpieza, validación y tipado |
| Marts | 03:30 | Actualización de fact + dim |
| Dashboard cache | 04:00 | Looker/PBI scheduled refresh |
| Monitor de calidad | 04:30 | Query de alertas de actividad por tienda |

Total: **pipeline completo en ~2 horas**. El dashboard está listo a las 04:00, antes de que el equipo inicie operaciones.

Para el VP de Operaciones que necesite datos en tiempo real durante el día: un pipeline adicional a las 12:00 con los datos de la mañana.

---

## Parte C — Gobernanza

### ¿Cómo proteger `customer_id` para cumplir con políticas de privacidad?

**Tres capas de protección:**

1. **Pseudonimización en STAGING:** `customer_id` se reemplaza con un hash SHA-256 salado (`customer_key_hashed`) antes de llegar a los marts. La tabla de equivalencia (`customer_id` ↔ `customer_key_hashed`) vive en un proyecto de BigQuery separado con acceso restringido a solo el equipo de Data Privacy y el pipeline.

2. **Column-level security en BigQuery:** Se aplica `COLUMN DATA POLICY` sobre `customer_id` en las tablas RAW. Solo usuarios con el rol `data_steward` pueden ver el valor real; el resto ve `REDACTED`.

3. **Row Access Policies:** Los analistas de tienda solo pueden ver datos de sus propias tiendas. Los analistas regionales ven su región. El acceso cross-tienda requiere aprobación del Data Owner.

---

### ¿Quién debería ser el Data Owner de la tabla de transacciones?

**Data Owner recomendado:** El equipo de **Operaciones Comerciales / Trade** (no el equipo de TI ni el equipo de Data).

**Justificación:**
- El Data Owner define las reglas de negocio (¿qué cuenta como `COMPLETED`? ¿cómo se trata un `RETURNED` parcial?).
- Operaciones es quien genera y comprende los datos; TI solo los transporta.
- El equipo de Data es el *Data Steward* (custodia técnica), no el propietario semántico.
- En la práctica: el Director de Operaciones firma el Data Asset Registration, y el equipo de Data Engineering se encarga del SLA de disponibilidad.

---

### Si dos reportes muestran GMV diferente para la misma tienda y el mismo día — ¿cuál sería tu proceso?

**Proceso de reconciliación (5 pasos):**

1. **Identificar la discrepancia exacta:** ¿Cuánta diferencia? ¿En qué fecha exacta? ¿Ambos reportes usan el mismo filtro de `status`? (El filtro `COMPLETED` vs. `COMPLETED + RETURNED` es la causa #1 de diferencias).

2. **Rastrear la definición de GMV en cada reporte:**
   - Reporte A usa `total_amount` de `transactions`?
   - Reporte B usa `SUM(unit_price × quantity)` de `transaction_items`?
   - Recordar hallazgo del Bloque 0: hay 1,745 transacciones `COMPLETED` donde `total_amount ≠ subtotal calculado`.

3. **Comparar contra la fuente de verdad (tabla RAW):** El dato en la capa RAW, antes de cualquier transformación, es el árbitro. Si ambos reportes divergen del RAW, hay un bug en al menos uno de los pipelines.

4. **Documentar la causa raíz en el Data Catalog:** Actualizar la definición oficial de GMV: "SUM(total_amount) WHERE status='COMPLETED' AND total_amount > 0". Todos los reportes deben usar la misma definición.

5. **Implementar test de consistencia automático:** Agregar una prueba en dbt que verifique que el GMV en `fact_transactions` ± 0.01% coincide con el GMV en `fact_transaction_items` (ya calculado en el Bloque 0). Si falla → el pipeline se detiene y alerta al Data Steward.
