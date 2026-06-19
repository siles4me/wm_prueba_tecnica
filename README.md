# Prueba Técnica — Data Analyst · Retail Multiformato Centroamérica

**Programa de Mejora de Productividad de Tiendas**  
Análisis completo en 6 bloques sobre datos de transacciones de 40 tiendas, 5 países, 18 meses (Ene 2024 – Jun 2025). 174,880 transacciones totales.

---

## Estructura del Repositorio

```
CasoTecnico/
│
├── Datasets/                        # Datos fuente originales (CSV)
│   ├── transactions.csv             # 174,880 filas — 171,324 COMPLETED + 3,553 RETURNED
│   ├── transaction_items.csv        # 542,015 líneas de ítem
│   ├── stores.csv                   # 40 tiendas, 5 países, 4 formatos
│   ├── products.csv                 # Catálogo de productos con costo
│   ├── vendors.csv                  # Proveedores con tier y país
│   └── store_promotions.csv         # Asignaciones de promociones por tienda
│
├── bloque0_auditoria.ipynb          # Auditoría exploratoria (Jupyter Lab)
├── bloque0_auditoria.md             # Resumen de hallazgos del EDA inicial
│
├── bloque1_queries.sql              # 6 queries BigQuery Standard SQL
│
├── bloque2_decisiones.md            # Modelo dimensional + pipeline ETL/ELT + gobernanza
├── bloque2_modelo.pdf               # Diagrama del modelo dimensional
├── bloque2_modelo.png               # Idem en PNG
│
├── bloque3_analisis.ipynb           # EDA profundo + A/B Test (Jupyter Lab)
├── bloque3_visualizaciones/         # Gráficos generados por bloque3_analisis.ipynb
│
├── bloque4_kpi_framework.md         # Framework de 8 KPIs + North Star
│
├── bloque5_dashboard.html           # Dashboard mockup para replicar en Power BI
├── bloque5_presentacion_EN.html     # Presentación ejecutiva 5 slides (English)
│
├── results.json                     # Métricas pre-calculadas (fuente de verdad para notebooks)
│
└── prueba_tecnica.pdf               # Enunciado original (referencia)
```

---

## Cómo Reproducir los Resultados

### Requisitos

```
Python 3.11+
pandas >= 2.0
numpy
matplotlib
scipy
nbformat
```

### Instalación del entorno

```bash
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt
```

### Orden de ejecución

```bash
# 1. Calcular todas las métricas analíticas
.venv/Scripts/python.exe compute_results.py
# → genera results.json

# 2. Diagrama del modelo dimensional
.venv/Scripts/python.exe build_bloque2_diagram.py
# → genera bloque2_modelo.pdf, bloque2_modelo.png

# 3. Notebook de EDA profundo + A/B Test
.venv/Scripts/python.exe build_bloque3_notebook.py
# → genera bloque3_analisis.ipynb (abrir en Jupyter Lab)

# 4. Dashboard HTML
.venv/Scripts/python.exe build_bloque5_dashboard.py
# → genera bloque5_dashboard.html (abrir en navegador)

# 5. Presentación ejecutiva
.venv/Scripts/python.exe build_bloque5_presentation.py
# → genera bloque5_presentacion_EN.html (abrir en navegador → imprimir a PDF)
```

> Los notebooks (`bloque0_auditoria.ipynb` y `bloque3_analisis.ipynb`) fueron construidos como scripts Python por reproducibilidad y están listos para ejecutarse en **Jupyter Lab** (`jupyter lab` desde el directorio del proyecto).

---

## Resumen por Bloque

### Bloque 0 — Auditoría de Datos
- 8 dimensiones de calidad auditadas: completitud, unicidad, consistencia, tipos, rangos, integridad referencial, business rules, patrones temporales.
- Hallazgos clave:
  - `unit_price = 0` en 231 ítems (~0.04% del total) con `was_on_promo = FALSE` — excluidos del GMROI
  - Transacciones `RETURNED`: 3,553 registros (2.0% del total) — excluidas de GMV
  - 1,717 transacciones COMPLETED con `total_amount ≠ sum(unit_price×qty)` — diferencias por descuentos de cabecera; se usa `total_amount` como fuente canónica
  - 50 transacciones anteriores a `opening_date` de la tienda — excluidas
  - 2 tiendas con doble asignación en el A/B test (TIENDA_008, TIENDA_037) — excluidas del análisis experimental
  - 1 tienda con gap de 8 días consecutivos sin ventas — alerta de monitoreo

### Bloque 1 — SQL BigQuery
6 queries de producción:
| Query | Descripción |
|-------|-------------|
| Q1 | Comp Sales YoY — solo tiendas con ≥13 meses de antigüedad |
| Q2 | GMV/m² por tienda y formato (Q2 2025) |
| Q3 | GMROI por proveedor con clasificación de riesgo |
| Q4 | Cohortes de retención de clientes de lealtad (M1–M6) |
| Q5 | Detección de quiebres de stock (gap-and-island, ≥3 días consecutivos) |
| Q6 | Análisis de basket size: BASKET_UPLIFT_REAL / SOLO_EFECTO_PRECIO / VOLUMEN_SIN_TICKET_EXTRA / SIN_EFECTO_CLARO |

### Bloque 2 — Modelo Dimensional
- **Star Schema** con 2 fact tables: `fact_transactions` (grain: 1 transacción) + `fact_transaction_items` (grain: 1 line item)
- 5 dimensiones: `dim_date`, `dim_store` (SCD Type 2), `dim_customer` (key=-1 para anónimos), `dim_product`, `dim_vendor`
- **SCD Type 2** en `dim_store` para preservar historial de `size_sqm` y `format` (crítico para GMV/m² histórico correcto)
- ETL: carga incremental nocturna (2:30am), ventana de 48h lookback, MERGE upsert en BigQuery

### Bloque 3 — EDA + A/B Test
**EDA:**
- Estacionalidad semanal (ISO week), análisis Pareto por formato, heatmap de retención por cohorte
- Detección de quiebres de stock por categoría, análisis GMV por país y método de pago

**A/B Test (nueva estrategia de exhibición en tienda):**
- Período: Sep 1 – Oct 12, 2024 · 20 tiendas tratamiento / 18 control (excluidas 2 con doble asignación)
- **Resultado: p = 0.0183, lift = -16.98%** → la nueva exhibición estuvo asociada a menor GMV en treatment
- **Limitación del diseño:** Pre-test balance fallido (p=0.0002) — Control tenía más HIPERMERCADO (5 vs 2); grupos no estratificados por formato. El efecto negativo puede estar parcialmente inflado por este desbalance.
- **Recomendación: NO implementar.** Replicar con asignación estratificada por formato antes de conclusión definitiva.

### Bloque 4 — Framework de 8 KPIs
| # | KPI | Dimensión | Target | Frecuencia |
|---|-----|-----------|--------|-----------|
| 1 ⭐ | GMV/m² | Productividad Tienda | +5% YoY | Semanal |
| 2 | Comp Sales Growth | Productividad Tienda | ≥+5% YoY | Mensual |
| 3 | Ticket Promedio | Productividad Tienda | Por formato | Semanal |
| 4 | Retención M1 | Experiencia Cliente | ≥40% | Mensual |
| 5 | Penetración Lealtad | Experiencia Cliente | ≥45% | Semanal |
| 6 | Índice Satisfacción | Experiencia Cliente | ≥60/100 | Mensual |
| 7 | GMROI por Proveedor | Desempeño Proveedor | ≥1.5x | Trimestral |
| 8 | Tasa Quiebre Stock | Desempeño Proveedor | <5% | Mensual |

### Bloque 5 — Dashboard + Presentación
- `bloque5_dashboard.html`: Mockup HTML funcional con gráficos embedded (base64 PNG). Se entrega como mockup estático en lugar de `.pbix` dado el acceso limitado a licencias Power BI Desktop en el entorno de desarrollo; cada sección incluye comentarios `<!-- PBI: ... -->` con instrucciones detalladas para replicar cada visual en Power BI.
- `bloque5_presentacion_EN.html`: 5 slides ejecutivos en inglés. Abrir en Chrome/Edge → Imprimir → Guardar como PDF (escala 100%, márgenes mínimos).

---

## Hallazgos Clave (Top 5)

1. **Comp Sales +6.55% YoY** — supera el target de +5%. EXPRESS lidera con +11.52%.
2. **10 tiendas BAJO_RENDIMIENTO** — todas formato DESCUENTO, por debajo del P25 de GMV/m².
3. **A/B Test negativo**: nueva exhibición en tienda redujo GMV -16.98% (p=0.0183). **No implementar.** (Caveat: balance pre-test falló, p=0.0002 — grupos no estratificados por formato.)
4. **Concentración de riesgo**: Electrónica = 52.6% del GMV total, con quiebres de stock en Proveedor U.
5. **GMROI crítico**: 118 combinaciones proveedor-categoría con GMROI < 1.0x (destruyen valor: costo > margen). 126 combinaciones por debajo del target operativo de 1.5x. Priorizar renegociación con proveedores Tier C.

---

## Uso de IA en este Proyecto

Esta prueba técnica fue desarrollada con asistencia de **Claude (Anthropic)** como herramienta de productividad.

### Prompts específicos utilizados

| Tarea | Prompt usado | Qué se realizo manualmente |
|-------|-------------|--------------------------|
| Query 5 (stockout) | *"Escribe una query BigQuery para detectar quiebres de stock usando la técnica gap-and-island con GENERATE_DATE_ARRAY y UNNEST. Criterio: 3+ días consecutivos sin ventas en tiendas donde el ítem históricamente se vende (≥7 días de historia). Devuelve store_id, item_id, fechas del gap, duración y GMV perdido estimado como avg_diario × días. Ordena por GMV perdido descendente."* | Añadió el filtro de `unit_price > 0` (hallazgo B0), ajustó el umbral de historia de 7 días, verificó que el island_id fuera correcto con datos reales |
| Query 6 (basket) | *"Escribe una query BigQuery que compare ticket promedio y unidades promedio entre transacciones con y sin ítems en promoción, por categoría. Pivota el resultado para tener columnas con_promo y sin_promo. Agrega una columna de interpretación: BASKET_UPLIFT_REAL si suben tanto ticket como unidades, SOLO_EFECTO_PRECIO si solo sube el ticket, etc."* | Definió las 4 categorías de clasificación, corrigió el alias `tf_full` → `tx_full`, validó que el join con `transaction_items` usara la granularidad correcta |
| Diagrama Star Schema | *"Genera un diagrama de Star Schema en Python con matplotlib para un modelo de retail. Tablas: fact_transactions, fact_transaction_items, dim_date, dim_store (SCD Type 2), dim_customer, dim_product, dim_vendor. Usa colores distintos para facts y dims, muestra los campos con tipo de dato, marca PK y FK con etiquetas de texto (no emojis)."* | Definió los campos exactos de cada tabla, añadió la nota de SCD Type 2, corrigió las coordenadas de las flechas FK |
| Dashboard HTML | *"Genera un archivo HTML con CSS que funcione como mockup de dashboard de retail. Debe tener: header con 4 KPI cards con variación semana anterior, barra de filtros, gráfico de comp sales, ranking de tiendas y una alerta para tiendas BAJO_RENDIMIENTO. Embebe los gráficos como base64 PNG generados con matplotlib. Incluye comentarios <!-- PBI: --> en cada sección para guiar la replicación en Power BI."* | Estructuró el orden de secciones según requerimiento del PDF, definió qué datos de `results.json` van en cada visual, verificó que todos los números coincidieran con el análisis |
| Corrección de errores | *"Este código lanza ValueError: operands could not be broadcast together with shapes (27,) (26,). El problema está en fill_between donde w24 y w25 tienen distinta longitud. Corrige alineando ambas series al mínimo de longitud."* | Identificó la causa raíz (distinto número de semanas entre años), evaluó si la corrección era correcta semánticamente |

### Qué NO fue delegado a IA
- **Decisiones analíticas**: elección del North Star (GMV/m² sobre NPS o ticket), diseño de dos fact tables separadas, selección de SCD Type 2 para dim_store, umbral de 3 días para quiebre de stock, interpretación del A/B test
- **Lógica de negocio**: definición de "tiendas comparables" (≥13 meses), criterio BAJO_RENDIMIENTO (P25 dentro del formato), targets por formato en el KPI framework
- **Hallazgos de auditoría**: identificación de unit_price=0, transacciones pre-opening_date, doble asignación en el experimento — todos detectados mediante exploración directa de los datos
- **Validación de resultados**: verificación manual de que GMV total, comp growth y resultados del A/B test eran coherentes con el contexto de negocio. Se detectó y corrigió el desbalance de formato en el diseño experimental.

### Transparencia
Todos los scripts Python son reproducibles determinísticamente: `compute_results.py` → `results.json` → builders. Cualquier número en los entregables tiene trazabilidad directa a la línea de código que lo genera.

---

*Prueba Técnica · Data Analyst · Retail Multiformato Centroamérica · 2025*
