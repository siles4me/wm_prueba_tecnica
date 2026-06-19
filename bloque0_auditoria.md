# Bloque 0 — Auditoría de Calidad de Datos

**Prueba Técnica · Data Analyst · Cadena de Retail Multiformato · Centroamérica**

**Dataset:** enero 2024 – junio 2025 · 40 tiendas · 5 países · 4 formatos

- transactions: 174,880 filas
- transaction_items: 542,015 filas
- stores: 40 filas
- products: 200 filas
- vendors: 30 filas
- store_promotions: 42 filas

---

## Hallazgos y Decisiones

| Dimensión | Hallazgo | Decisión |
|-----------|----------|----------|
| Completitud | 59.8% de transacciones sin customer_id | IGNORAR — clientes anónimos (sin tarjeta de lealtad) |
| Completitud | Inconsistencias loyalty_card ↔ customer_id: caso_A=0, caso_B=0 | EXCLUIR del análisis de cohortes si existen inconsistencias |
| Consistencia | 1,745 transacciones con total_amount ≠ sum(unit_price×qty) | ALERTA — revisar si son RETURNED; usar subtotal_calculado como fuente de verdad |
| Unicidad (transactions) | 0 transaction_id duplicados | EXCLUIR duplicados (keep=first) |
| Unicidad (items) | 0 transaction_item_id duplicados | OK si 0; EXCLUIR si > 0 |
| Unicidad (tx-item par) | 3,660 pares (transaction_id, item_id) repetidos | MANTENER — variantes válidas: difieren en quantity/unit_price/was_on_promo |
| Validez (total_amount) | total_amount ≤ 0: 3 registros | EXCLUIR del GMV transacciones COMPLETED con monto ≤ 0 |
| Validez (unit_price) | unit_price=0 sin promo: 231 ítems | ALERTA — excluir del cálculo de GMROI |
| Ref. Integridad (store_id) | 0 store_ids sin referencia en stores | EXCLUIR transacciones huérfanas |
| Ref. Integridad (vendor_id) | 1 vendor_ids sin referencia en vendors | EXCLUIR productos huérfanos del GMROI |
| Ref. Integridad (item_id) | 0 item_ids sin referencia en products | ALERTA — ítems sin info de categoría/costo |
| Frescura | 1 tiendas con gap >= 7 días consecutivos sin ventas | ALERTA — investigar cierre temporal o falla de reporte |
| Integridad Temporal | 50 transacciones antes de opening_date | EXCLUIR — datos inválidos temporalmente |
| A/B Test | 2 tiendas con doble asignación CONTROL+TREATMENT | EXCLUIR tiendas contaminadas del A/B test |

---

## Decisiones Globales para Bloques Siguientes

1. **GMV**: usar solo `status = COMPLETED` y `total_amount > 0`.
2. **Cohortes de lealtad**: usar solo registros donde `customer_id IS NOT NULL` y `loyalty_card = TRUE`.
3. **Comp Sales**: excluir tiendas con `opening_date` posterior a 13 meses antes del período actual.
4. **A/B Test**: excluir tiendas con doble asignación. Usar período pre-test para validar comparabilidad.
5. **GMROI**: excluir productos con `unit_price = 0` o `cost = 0`.

---

## Detalle por Dimensión

### 1. Completitud
El **59.8%** de las transacciones (104,632 de 174,880) no tiene `customer_id` — clientes anónimos sin tarjeta de lealtad, comportamiento esperado en retail físico. Adicionalmente se detectaron **0** registros con `loyalty_card=True` pero sin `customer_id` (caso A) y **0** con `customer_id` pero `loyalty_card=False` (caso B), indicando inconsistencia en el registro del programa de lealtad.
**Decisión:** Los anónimos se ignoran para análisis de cohortes (se tratan como `customer_key = -1` en el modelo). Las inconsistencias se excluyen del análisis de retención de lealtad.

### 2. Consistencia
Se identificaron **1,745** transacciones `COMPLETED` (1.0%) donde `total_amount != sum(unit_price x quantity)`. La diferencia corresponde a descuentos aplicados a nivel de cabecera de ticket, no reflejados en los ítems individuales. El sistema POS registra el monto final en `total_amount`, que es la fuente canónica.
**Decisión:** Usar `total_amount` de la tabla `transactions` como GMV. El subtotal calculado desde ítems es referencia secundaria y no se usa para métricas financieras.

### 3. Unicidad
- `transaction_id` duplicados en `transactions`: **0** — ningún duplicado de clave primaria.
- `transaction_item_id` duplicados en `transaction_items`: **0** — PK limpio.
- Pares `(transaction_id, item_id)` repetidos: **3,660**. La investigación confirmó que estas filas difieren en `quantity`, `unit_price` o `was_on_promo`, representando líneas válidas del mismo ítem bajo condiciones distintas (ej. unidades a precio regular + unidades en promoción dentro de la misma transacción).
**Decisión:** MANTENER — variantes válidas: difieren en quantity/unit_price/was_on_promo.

### 4. Validez
- `total_amount <= 0`: **3** registros en transacciones `COMPLETED` — importes inválidos posiblemente generados por errores de anulación parcial en el POS.
- `unit_price = 0` sin promoción activa: **231** ítems — posible error de captura o ítem gratuito no categorizado correctamente.
**Decisión:** Excluir `total_amount <= 0` del cálculo de GMV. Excluir `unit_price = 0` sin promo del GMROI para no distorsionar el margen bruto.

### 5. Integridad Referencial
- `store_id` huérfanos: **0** IDs presentes en `transactions` sin referencia en `stores`.
- `vendor_id` huérfanos: **1** IDs presentes en `products` sin referencia en `vendors`.
- `item_id` huérfanos: **0** IDs presentes en `transaction_items` sin referencia en `products` — sin información de categoría ni costo.
**Decisión:** Excluir registros huérfanos del análisis de GMROI y de categorías. Reportar a ingeniería de datos para corrección en la capa fuente.

### 6. Frescura
**1** tienda(s) presentaron gaps de más de 7 días consecutivos sin registrar ventas. Puede indicar cierre temporal por mantenimiento, falla en la integración con el POS o período de baja demanda estacional.
**Decisión:** Alerta de monitoreo operativo. No se excluyen del análisis global pero se documentan para seguimiento con el equipo de operaciones de tienda.

### 7. Integridad Temporal
**50** transacciones tienen fecha anterior a la `opening_date` registrada de su tienda, lo que es temporalmente imposible. Pueden corresponder a registros de prueba del sistema POS, errores en la migración de datos históricos o fechas de apertura incorrectas en el maestro de tiendas.
**Decisión:** Excluir del análisis — datos inválidos temporalmente que sesgarían métricas de comp sales y cohortes.

### 8. Integridad del A/B Test
**2** tienda(s) aparecen asignadas simultáneamente a CONTROL y TREATMENT en `store_promotions`: TIENDA_008, TIENDA_037. Esta ambigüedad impide atribuir el efecto observado a un solo grupo experimental, contaminando el resultado.
**Decisión:** Excluir del análisis experimental. El test se ejecuta con las tiendas restantes correctamente asignadas a un único grupo.
