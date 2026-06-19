# Bloque 4 — Framework de KPIs desde Cero

**Programa de Mejora de Productividad de Tiendas**  
**Prueba Técnica · Data Analyst · Cadena de Retail Multiformato · Centroamérica**

---

## North Star Metric

> ### GMV por Metro Cuadrado (GMV/m²)

**Fórmula:** `SUM(total_amount WHERE status='COMPLETED' AND total_amount > 0) / SUM(size_sqm)`

**Justificación:** En retail de formato físico, el espacio es el activo más costoso y difícil de escalar. GMV/m² es el único KPI que conecta simultáneamente tres dimensiones críticas: (1) eficiencia del espacio físico, (2) desempeño comercial y (3) comparabilidad entre formatos distintos. Un HIPERMERCADO de 8,000 m² y un EXPRESS de 400 m² no son comparables en GMV absoluto, pero sí en GMV/m². Este KPI le permite a la dirección priorizar inversiones, detectar tiendas sub-utilizadas y tomar decisiones de expansión basadas en evidencia.

---

## Tabla de KPIs (8 KPIs)

### DIMENSIÓN 1: Productividad de Tienda (3 KPIs)

---

#### KPI 1 — GMV/m² *(North Star)*

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Ingresos netos por metro cuadrado de piso de ventas, en el período |
| **Fórmula** | `SUM(total_amount) / store_size_sqm` — solo transacciones COMPLETED con total_amount > 0 |
| **Frecuencia** | Semanal (monitoreo), Mensual (objetivo), Trimestral (evaluación estratégica) |
| **Fuente de datos** | `fact_transactions` JOIN `dim_store` |
| **Target sugerido** | Varía por formato: HIPERMERCADO ≥ $X/m², DESCUENTO ≥ $Y/m². Baseline: P75 del primer trimestre del año. Incremento anual esperado: +5% |
| **¿Cómo detectas si el dato está mal?** | (1) GMV/m² < 0 (monto negativo sin filtrar RETURNED). (2) GMV/m² cae >30% semana a semana sin cierre de tienda → posible dato faltante. (3) size_sqm = 0 o NULL → división por cero. Monitor en pipeline. |

---

#### KPI 2 — Comp Sales Growth (YoY)

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Crecimiento del GMV en tiendas comparables (misma tienda, mismo período del año anterior). Excluye tiendas abiertas hace < 13 meses |
| **Fórmula** | `(GMV_período_actual - GMV_mismo_período_año_anterior) / GMV_mismo_período_año_anterior × 100` |
| **Frecuencia** | Mensual y trimestral |
| **Fuente de datos** | `fact_transactions` JOIN `dim_store` (filtrar `opening_date ≤ fecha_corte - 13 meses`) |
| **Target sugerido** | ≥ +5% YoY por formato. Alerta si < +2% (crecimiento por debajo de inflación). |
| **¿Cómo detectas si el dato está mal?** | (1) Una tienda mueve de "comp" a "no-comp" sin razón (cambio en opening_date → auditar dim_store). (2) Comp Growth > +50% o < -50% → verificar si hubo cierre temporal en el año anterior. (3) Número de tiendas comp cambia significativamente vs. mes anterior → alertar al Data Steward. |

---

#### KPI 3 — Ticket Promedio por Formato *(KPI compuesto)*

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Monto promedio de las transacciones COMPLETED por formato de tienda. KPI compuesto porque se deriva del GMV total dividido entre el número de transacciones |
| **Fórmula** | `SUM(total_amount) / COUNT(DISTINCT transaction_id)` — filtrado igual que GMV/m² |
| **Frecuencia** | Semanal |
| **Fuente de datos** | `fact_transactions` JOIN `dim_store` |
| **Target sugerido** | HIPERMERCADO > $350 · SUPERMERCADO > $250 · DESCUENTO > $150 · EXPRESS > $120. Variación semana a semana: alarma si cae >10% |
| **¿Cómo detectas si el dato está mal?** | (1) Ticket < $1 → probable error de transacción (unit_price=0, ver hallazgo Bloque 0). (2) Ticket > $5,000 en DESCUENTO → atípico, verificar si es una compra institucional o error. (3) Ticket sube drásticamente sin cambio en mix de categorías → revisar si se filtraron correctamente los RETURNED. |

---

### DIMENSIÓN 2: Experiencia del Cliente (3 KPIs)

---

#### KPI 4 — Tasa de Retención de Lealtad M1 *(Leading Indicator)*

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Porcentaje de clientes con tarjeta de lealtad que realizan una segunda compra en el mes siguiente a su primera transacción. Es un **leading indicator** porque predice el LTV del cliente antes de que sea observable |
| **Fórmula** | `COUNT(DISTINCT customer_id WHERE segunda_compra_en_mes_1) / COUNT(DISTINCT customer_id_cohorte_mes_0) × 100` |
| **Frecuencia** | Mensual (por cohorte de activación) |
| **Fuente de datos** | `fact_transactions` (filtrar loyalty_card=TRUE, customer_id IS NOT NULL) |
| **Target sugerido** | ≥ 40% al Mes 1. Alerta si < 30% → el programa de reactivación tiene fallas. |
| **¿Cómo detectas si el dato está mal?** | (1) Tasa > 100% (error de conteo por duplicados en customer_id). (2) Tasa cae a 0% para una cohorte → verificar que los datos de ese mes llegaron al warehouse. (3) Cohorte con 0 clientes → verificar que el pipeline del CRM procesó correctamente. |

---

#### KPI 5 — Penetración de Lealtad

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Porcentaje de transacciones realizadas por clientes identificados (con tarjeta de lealtad activa) |
| **Fórmula** | `COUNT(tx WHERE loyalty_card=TRUE) / COUNT(tx_total) × 100` |
| **Frecuencia** | Semanal y mensual |
| **Fuente de datos** | `fact_transactions` |
| **Target sugerido** | ≥ 45% del total de transacciones. Línea base actual: ~40%. Crecimiento esperado: +2pp por trimestre. |
| **¿Cómo detectas si el dato está mal?** | (1) Penetración > 100% o < 0% (imposible). (2) Caída súbita de >5pp en una semana → posible error en campo loyalty_card en el POS de alguna tienda. (3) Penetración = 100% en alguna tienda → el campo loyalty_card puede estar defaulteando a TRUE. |

---

#### KPI 6 — Índice de Satisfacción del Formato *(KPI compuesto)*

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Indicador compuesto que combina Ticket Promedio normalizado + Tasa de Retención M1 + GMV/m² normalizado, para una puntuación integral de salud del formato. Calculado como promedio de los 3 KPIs normalizados (0-100) |
| **Fórmula** | `(normalize(ticket_prom) + normalize(ret_m1) + normalize(gmv_sqm)) / 3` — donde normalize(x) = (x - min) / (max - min) × 100 dentro del formato |
| **Frecuencia** | Mensual |
| **Fuente de datos** | Calculado sobre `fact_transactions` + tabla de retención de cohortes |
| **Target sugerido** | ≥ 60 puntos (escala 0-100). Por debajo de 40 = intervención urgente requerida. |
| **¿Cómo detectas si el dato está mal?** | (1) Índice = 0 o 100 para todas las tiendas → la normalización no tiene varianza suficiente (todos los datos son iguales → revisar que el período tiene datos completos). (2) Índice de una tienda cambia >20 puntos de un mes a otro sin causa operativa → uno de los tres componentes tiene dato incorrecto, revisar individualmente. |

---

### DIMENSIÓN 3: Desempeño de Proveedor (2 KPIs)

---

#### KPI 7 — GMROI por Proveedor

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Margen Bruto Retornado sobre la Inversión en Costo del Proveedor. Mide cuánto margen genera cada unidad de costo invertido en el proveedor |
| **Fórmula** | `(SUM(unit_price × quantity) - SUM(cost × quantity)) / SUM(cost × quantity)` — solo ítems con unit_price > 0 y cost > 0 |
| **Frecuencia** | Trimestral |
| **Fuente de datos** | `fact_transaction_items` JOIN `dim_product` JOIN `dim_vendor` |
| **Target sugerido** | GMROI ≥ 1.5 por proveedor. GMROI < 1.0 = "proveedor en riesgo" (genera menos margen que su costo). Acción: renegociar términos o descontinuar. |
| **¿Cómo detectas si el dato está mal?** | (1) GMROI < 0 (imposible con unit_price > cost) → verificar que cost > 0 y no hay devoluciones mal contabilizadas. (2) GMROI > 20 (extremadamente alto) → posible error en cost (muy bajo) → auditar contra el sistema de compras. (3) Número de SKUs activos de un proveedor cae a 0 → puede ser cierre de relación comercial, verificar con el equipo de compras. |

---

#### KPI 8 — Tasa de Quiebre de Stock por Proveedor

| Campo | Descripción |
|-------|-------------|
| **Definición exacta** | Porcentaje de días-tienda-ítem donde un SKU del proveedor tuvo quiebre de stock (≥3 días consecutivos sin venta en tiendas donde históricamente se vende) |
| **Fórmula** | `COUNT(días_en_quiebre ≥ 3 consecutivos) / COUNT(días_esperados_activos) × 100` — por proveedor |
| **Frecuencia** | Mensual |
| **Fuente de datos** | Query 5 del Bloque 1 (SQL) → tabla derivada `mart.stockout_events` |
| **Target sugerido** | < 5% de días en quiebre por proveedor. Proveedor con > 15% = "proveedor crítico de abastecimiento". |
| **¿Cómo detectas si el dato está mal?** | (1) Tasa de quiebre = 100% para todos los ítems de un proveedor → posible que el proveedor no tuvo transacciones en el período (verificar si hay error de reporte). (2) Tasa de quiebre = 0% para todos → verificar que el script de detección de gaps corrió correctamente y que el umbral de 3 días no fue cambiado accidentalmente. (3) El número de SKUs monitoreados cambia significativamente → revisar el filtro de "ítems históricamente activos" (≥7 días de ventas). |

---

## Resumen del Framework

| # | KPI | Dimensión | Tipo | Target | Frecuencia |
|---|-----|-----------|------|--------|------------|
| 1 | **GMV/m² ⭐** | Productividad Tienda | North Star | +5% YoY | Semanal |
| 2 | Comp Sales Growth | Productividad Tienda | Resultado | ≥+5% YoY | Mensual |
| 3 | Ticket Promedio por Formato | Productividad Tienda | Compuesto | Por formato | Semanal |
| 4 | **Tasa de Retención M1** | Experiencia Cliente | Leading | ≥40% | Mensual |
| 5 | Penetración de Lealtad | Experiencia Cliente | Resultado | ≥45% | Semanal |
| 6 | Índice de Satisfacción Formato | Experiencia Cliente | Compuesto | ≥60/100 | Mensual |
| 7 | GMROI por Proveedor | Desempeño Proveedor | Resultado | ≥1.5x | Trimestral |
| 8 | Tasa de Quiebre de Stock | Desempeño Proveedor | Leading | <5% | Mensual |

**Leyenda:**
- ⭐ North Star Metric
- **Leading indicator:** KPI 4 (Retención M1) — predice el LTV antes de que sea observable; KPI 8 (Quiebre de Stock) — predice pérdida de GMV futura antes de que ocurra
- **KPI compuesto:** KPI 3 (Ticket = GMV / Transacciones) y KPI 6 (Índice Satisfacción = promedio normalizado de 3 KPIs)

---

## Notas de Implementación

1. **Gobernanza:** Cada KPI debe tener un Data Owner asignado (ver Bloque 2, Parte C). Propuesta: GMV-related KPIs → equipo de Operaciones Comerciales; KPIs de lealtad → equipo de Marketing; KPIs de proveedor → equipo de Compras.

2. **Calendario de revisión:** Los KPIs semanales van al dashboard operativo (Bloque 5). Los mensuales/trimestrales van al Business Review con el VP de Operaciones.

3. **Benchmarking:** Para el primer trimestre, el target es el P75 actual de cada KPI dentro del formato. En el segundo año se puede incorporar benchmarking externo de retail centroamericano.
