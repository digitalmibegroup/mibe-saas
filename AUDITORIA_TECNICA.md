# 📋 AUDITORÍA TÉCNICA — LA CAVA LICORERA

> **Fuente:** Inspección directa de archivos en `D:\Claude IA\La cava oficial - Sistema interno\` + esquema real de Supabase consultado vía API.
> **Fecha auditoría:** 2026-05-29
> **Generado por:** Claude Sonnet/Opus — sesión de auditoría completa
> **Propósito:** Base de conocimiento permanente para futuras modificaciones del sistema.

---

## 1. 🎯 RESUMEN EJECUTIVO

| Aspecto | Detalle |
|---|---|
| **Nombre del proyecto** | La Cava Licorera (anteriormente "La Cava Oficial") |
| **Tipo** | Sistema de gestión interno (ERP/POS) para licorera |
| **Cliente comercial** | Mibe SaaS (Digital Mibe Group) — repo `digitalmibegroup/mibe-saas` |
| **Identificador de tenant** | `CID = 'lacava'` (multi-tenancy por columna `id_licencia`/`id_cliente`) |
| **Propósito** | Gestión integral de licorera con POS, inventario, clientes, contabilidad, programa de fidelización |
| **Arquitectura** | SPA monolítica HTML+JS vanilla en un único archivo de ~500KB, sin build step, sin framework |
| **Backend** | Supabase (PostgREST) — sin código backend propio |
| **Hosting** | Netlify (deploy estático desde carpeta `/deploy`) + Service Worker para PWA |
| **Usuarios objetivo** | Dueño + cajero de la licorera (1 sesión, 1 usuario hardcoded) |
| **Estado** | En producción, con licencia activa hasta `2027-12-31` |

**Casos de uso principales:**
1. **POS** — registrar ventas de licor con manejo de empaques (botella, sixpack, caja)
2. **Inventario** — gestionar productos con stock por unidad y por empaque
3. **Clientes** — registrar y fidelizar con programa de puntos
4. **Cartera** — vender a crédito y gestionar abonos
5. **Caja** — apertura/cierre de turno con conciliación
6. **Cotizaciones** — generar y enviar por WhatsApp
7. **Compras** — registrar entradas de inventario con proveedores
8. **Reportes** — ventas, inventario, rentabilidad
9. **Catálogo público** — tienda virtual para clientes finales (pedidos vía WhatsApp)

---

## 2. 🏗️ ARQUITECTURA

```
                      ┌─────────────────────────────────────────┐
                      │     CLIENTE FINAL (catalogo.html)        │
                      │   Tema oscuro · WhatsApp checkout        │
                      └────────────────┬────────────────────────┘
                                       │ READ
                                       ▼
┌──────────────────────────────────────────────────────────────────┐
│                    SUPABASE (PostgreSQL + PostgREST)              │
│            Proyecto: egjlrcokerffuoqwbxlh.supabase.co            │
│                                                                  │
│  Tablas:  licencias  inventario  ventas  detalle_ventas          │
│           clientes_frecuentes  puntos_clientes  puntos_transacc. │
│           gastos  compras  compras_items  proveedores            │
│                                                                  │
│  Auth: anon key compartida (RLS no observado)                    │
└────────────────────────────▲─────────────────────────────────────┘
                             │ HTTP REST (fetch directo)
┌────────────────────────────┴─────────────────────────────────────┐
│           DASHBOARD INTERNO (dashboard_lacava.html)              │
│                ~500KB · vanilla JS · single file                 │
│                                                                  │
│  Vistas:  vInicio · vPOS · vClientes · vInventario · vCompras    │
│           vGastos · vContabilidad · vVentas · vReportes          │
│           vPuntos · vPlan · vCatalogo · vCaja · vCotizaciones    │
│           vCartera                                                │
│                                                                  │
│  Estado local (localStorage):                                    │
│    • lcava_session_v1 (login 30 días)                            │
│    • lc_caja_actual / lc_caja_historial                          │
│    • lc_ventas_espera                                            │
│    • lc_cartera_local                                            │
│    • lc_cotizaciones                                             │
│    • lc_pos_last_visit                                           │
│    • lacava_cat_hidden                                           │
│    • canje_puntos_lacava                                         │
└──────────────────────────────────────────────────────────────────┘
                             ▲
                             │
┌────────────────────────────┴─────────────────────────────────────┐
│                           NETLIFY                                 │
│  Hosting estático · _redirects (`/` → `/dashboard_lacava.html`)  │
│  Service Worker (sw.js) → cache offline (lacava-v1)              │
│  Manifest PWA → instalable                                       │
└──────────────────────────────────────────────────────────────────┘
                             ▲
                             │
                       ┌─────┴─────┐
                       │  WhatsApp │
                       │  Wa.me    │ Comunicación cliente (links externos)
                       │  3001785744│
                       └───────────┘
```

**Stack confirmado:**

| Capa | Tecnología | Versión / Detalle |
|---|---|---|
| Frontend | HTML5 + CSS3 + Vanilla JavaScript ES5/ES6 | Sin frameworks. Sin build. Single-file |
| Fuente UI | Plus Jakarta Sans (Google Fonts) | 400–800 |
| PWA | Service Worker + manifest.json | Cache `lacava-v1` |
| Backend | Supabase (PostgREST) | proyecto `egjlrcokerffuoqwbxlh` |
| Base de datos | PostgreSQL (gestionado por Supabase) | — |
| Autenticación | **No usa Supabase Auth** — login hardcoded en JS | usuario `lacava` / pass `cava2026` |
| Hosting | Netlify | sitio `lacava-sistema.netlify.app` |
| Repositorio | GitHub | `digitalmibegroup/mibe-saas` (rama `main`) |
| Importaciones | Google Sheets (CSV público) | para carga masiva de inventario |
| Mensajería | WhatsApp deep links (`wa.me/...`) | sin API oficial |

**Lo que NO existe:**
- No hay backend propio (Node, Python, etc.)
- No hay build pipeline (webpack, vite, etc.)
- No hay tests
- No hay TypeScript
- No hay sistema de migración de DB versionado en código
- No hay CI/CD pipeline configurado (Netlify auto-deploy es lo único)

---

## 3. 📁 ESTRUCTURA DEL PROYECTO

```
La cava oficial - Sistema interno/
├── dashboard_lacava.html        500.8 KB  ← Sistema interno (SPA)
├── index.html                   500.8 KB  ← Copia idéntica de dashboard (alias)
├── catalogo.html                 45.4 KB  ← Tienda pública (separada)
├── manifest.json                  0.5 KB  ← PWA manifest
├── sw.js                          1.5 KB  ← Service Worker
├── _redirects                     0.0 KB  ← Netlify: / → dashboard
├── icon-192.png / icon-512.png   15.2 KB  ← Iconos PWA
├── AUDITORIA_TECNICA.md                   ← Este documento
└── deploy/                                ← Copia exacta para producción
    ├── dashboard_lacava.html
    ├── index.html
    ├── catalogo.html
    ├── manifest.json
    ├── sw.js
    └── icon-*.png
```

**Observación crítica:** Hay **4 copias del mismo dashboard** (`dashboard_lacava.html` + `index.html` + `deploy/dashboard_lacava.html` + `deploy/index.html`). Toda modificación al sistema interno debe replicarse en los 4 archivos. Actualmente se sincronizan vía `Copy-Item` PowerShell.

**Carpetas que no son código del producto:**
- `.claude/` — configuración local de Claude Code (`launch.json` con preview server)
- `.git/` — repositorio Git

---

## 4. 🔄 FLUJOS FUNCIONALES PRINCIPALES

### 4.1 Flujo de arranque (init)

```
1. Carga HTML → setTimeout(init, 1400ms) [línea 2022]
2. init() verifica `sesionValida()` en localStorage (TTL 30 días)
3.   ├─ Sí: iniciarApp()
4.   └─ No: muestra #loginScreen
5. iniciarApp() ejecuta secuencialmente:
   a. checkLic() → GET /licencias?id_cliente=eq.lacava
      • Si activo=false o fecha vencida → showLock() [bloqueo total]
   b. setupTime() · keepAlive()
   c. cargarInventarioSB() → GET /inventario?id_licencia=eq.lacava
   d. loadDash() → KPIs y widgets de Resumen
   e. buildCatsPOS() · loadClis() · renderCajaBtn() · renderEspera()
```

### 4.2 Flujo de venta (POS → doVenta)

```
1. Usuario agrega productos al carrito (cart[])
2. Clic en "Registrar venta" → abrirConfirmacionVenta()
3. Modal de confirmación → muestra resumen
4. Clic en "Confirmar y registrar" → doVenta()
5. doVenta() ejecuta:
   a. Validaciones (cart no vacío)
   b. Cálculo de puntos:
      • esCartera || huboDescuento || total<50000 || sin WA → 0 pts
      • sino: pts = floor(total / 800)
   c. POST /ventas → obtiene venta.id
   d. POST /detalle_ventas (array)
   e. Descuento de stock local (respeta empaques) + actualizarStockSB()
   f. Si esCartera: saveCarteraLocal() en localStorage
   g. upsertCli() → actualiza/crea cliente
   h. procesarPuntosPorVenta() si pts>0
   i. Muestra modal con número, WhatsApp link, impresión
   j. Reset carrito
```

### 4.3 Flujo de canje de puntos

```
1. Usuario selecciona cliente con saldo de puntos
2. Agrega productos al canjeCart (cada producto cuesta: precio_venta / 16)
3. confirmarCanje():
   a. POST /ventas con estado='canje', total=0, metodo_pago='puntos'
   b. POST /detalle_ventas (con sufijo "(CANJE)")
   c. PATCH /puntos_clientes (resta puntos)
   d. POST /puntos_transacciones tipo='canje' con venta_id
   e. Descontar inventario (loop por producto)
   f. POST /gastos categoria='Fidelización' con costo total
      • Descripción incluye tag [canje:venta_id] para reversa
```

### 4.4 Flujo de cierre de caja

```
1. mostrarCierreCaja():
   • Calcula esperados desde VENTAS_MES filtradas por fecha_apertura
   • Solicita conteo físico (efReal, baReal)
2. confirmarCierreCaja():
   • Crea registro con difs
   • Push a CAJA_HISTORIAL (max 90 registros)
   • localStorage.setItem('lc_caja_historial')
   • Elimina CAJA_ACTUAL
   • showCierreExport() → opciones imprimir / WhatsApp
```

### 4.5 Flujo de cartera (CxC)

```
1. En POS, checkbox "Pago parcial / Crédito"
2. doVenta() con esCartera=true:
   • venta.estado='credito'
   • saveCarteraLocal() guarda en localStorage:
     {id, numero, cliente, wa, total, abono, saldo_pendiente,
      fecha_vencimiento, fecha_creacion, abonos_hist, estado_cartera}
3. Módulo Cartera lista CARTERA_LOCAL filtrado por estado
4. registrarAbono() actualiza saldo_pendiente y push a abonos_hist
```

---

## 5. 🧩 MÓDULOS DEL SISTEMA

| # | Módulo | Archivo HTML (vista) | Función JS principal | Storage | Riesgo de modificar |
|---|---|---|---|---|---|
| 1 | **Resumen / Inicio** | `#vInicio` | `loadDash()` | Supabase | 🟢 Bajo (solo lectura) |
| 2 | **POS** | `#vPOS` | `renderPOS()`, `addP()`, `doVenta()` | Supabase + localStorage | 🔴 Alto (afecta ventas + stock + puntos + cartera) |
| 3 | **Clientes** | `#vClientes` | `loadClientesView()` | Supabase | 🟡 Medio |
| 4 | **Inventario** | `#vInventario` | `renderInvTable()`, `guardarNuevoProd()` | Supabase | 🔴 Alto (todo depende del stock) |
| 5 | **Compras** | `#vCompras` | `guardarCompra()`, `recibirCompra()` | Supabase | 🟡 Medio (incrementa stock) |
| 6 | **Gastos** | `#vGastos` | `guardarGasto()` | Supabase | 🟢 Bajo |
| 7 | **Contabilidad** | `#vContabilidad` | `renderEstadoResultados()` | Supabase | 🟡 Medio (cálculos sensibles) |
| 8 | **Ventas** | `#vVentas` | `renderVentasList()`, `eliminarVenta()`, `guardarEdicionVenta()` | Supabase + localStorage | 🔴 Alto (afecta stock + puntos + cartera) |
| 9 | **Reportes** | `#vReportes` | `generarReporteVentas()`, `renderRepInventario()`, `renderRepRentabilidad()` | Supabase | 🟢 Bajo (solo lectura) |
| 10 | **Programa Puntos** | `#vPuntos` | `buscarPtsCliente()`, `confirmarCanje()`, `revertirCanje()` | Supabase + localStorage | 🔴 Alto (afecta saldos + inventario + contabilidad) |
| 11 | **Tienda Virtual (admin)** | `#vCatalogo` | `renderCatPanel()`, `toggleCatVisible()` | localStorage | 🟢 Bajo |
| 12 | **Mi Plan** | `#vPlan` | `initMiPlan()` | Supabase | 🟢 Bajo |
| 13 | **Caja** | `#vCaja` | `confirmarAperturaCaja()`, `confirmarCierreCaja()`, `abrirCorreccionCierre()` | localStorage | 🟡 Medio |
| 14 | **Cotizaciones** | `#vCotizaciones` | `guardarCotizacion()`, `convertirCotVenta()` | localStorage | 🟢 Bajo |
| 15 | **Cartera (CxC)** | `#vCartera` | `renderCarteraList()`, `registrarAbono()` | localStorage | 🟡 Medio |
| 16 | **Catálogo público** | `catalogo.html` (independiente) | `cargarProductos()`, `enviarPedidoWA()` | localStorage | 🟢 Bajo |

**Dependencias entre módulos:**

```
Inventario ──┬──> POS (lee stock, precios)
             ├──> Compras (escribe stock)
             ├──> Reportes (todos)
             ├──> Contabilidad (COGS)
             ├──> Canje Puntos (descuenta stock)
             └──> Catálogo público (productos visibles)

POS ─────────┬──> Ventas (registra)
             ├──> Cartera (si es crédito)
             ├──> Puntos (acumula)
             ├──> Clientes frecuentes
             └──> Caja (calcula esperados al cerrar)

Puntos ──────┬──> Inventario (canjes descuentan)
             ├──> Gastos (canjes generan gasto Fidelización)
             ├──> Ventas (canjes aparecen como movimiento estado='canje')
             └──> Clientes (saldo)

Caja ────────> Ventas del turno (filtro por fecha_apertura)
```

---

## 6. 🗄️ BASE DE DATOS

**Motor:** PostgreSQL gestionado por Supabase
**Acceso:** REST API (PostgREST) con `anon` key
**RLS observado:** No detectado (el anon key tiene permisos amplios)
**Multi-tenancy:** Por columna `id_licencia` (mayoría) o `id_cliente` (en `ventas` y `licencias`)

### 6.1 Esquema real (extraído de la API)

#### `licencias`
| Campo | Notas |
|---|---|
| `id` | PK |
| `created_at` | timestamp |
| `cliente` | text — nombre comercial |
| `activo` | bool — bloquea acceso si false |
| `plan` | text — "Plan Base", etc. |
| `vence` | date — bloquea acceso si Date.now() > vence |
| `whatsapp` | text |
| `id_cliente` | text — tenant key ("lacava") |

#### `inventario`
| Campo | Notas |
|---|---|
| `id` | PK (UUID) |
| `id_licencia` | FK tenant |
| `nombre`, `categoria`, `imagen` | texto |
| `precio_venta`, `precio_costo` | numeric — **precio_costo SIEMPRE a nivel empaque** |
| `stock` | int — cantidad de empaques |
| `stock_min` | int — umbral alerta |
| `empaque` | text — "unidad", "sixpack", "caja" |
| `uds_empaque` | int — unidades por empaque |
| `uds_sueltas` | int — unidades sueltas que NO completan un empaque |
| `created_at` | timestamp |

#### `clientes_frecuentes`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `nombre`, `whatsapp`, `direccion`, `detalle` |
| `puntos` (legacy, deprecated por `puntos_clientes`) |
| `total_compras`, `num_pedidos`, `ultima_compra` |

#### `ventas`
| Campo | Notas |
|---|---|
| `id` | PK UUID |
| `created_at` | timestamp |
| `id_cliente` | tenant key |
| `numero_venta` | int autoincremental |
| `cliente_nombre`, `cliente_whatsapp` |
| `subtotal`, `descuento`, `domicilio`, `total` |
| `metodo_pago` | 'efectivo' / 'transferencia' / 'nequi' / 'daviplata' / 'puntos' |
| `estado` | 'completada' / 'credito' / **'canje'** |
| `notas`, `es_promocion` |
| `puntos_ganados` |
| `direccion_entrega`, `detalle_entrega` |
| `abono`, `saldo_pendiente`, `fecha_vencimiento_cartera` | solo si estado='credito' |

#### `detalle_ventas`
| Campo | (inferido del código línea 2784) |
|---|---|
| `venta_id` | FK → ventas.id |
| `prod_id` | FK → inventario.id |
| `producto_nombre`, `categoria` |
| `cantidad` |
| `precio_unitario`, `precio_total` |
| `es_unidad` | bool — si fue venta de unidad suelta de un empaque |
| `uds_empaque` | int — snapshot al momento de la venta |

#### `gastos`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `fecha` (date), `categoria`, `descripcion`, `valor` |
| **Categoría especial:** `'Fidelización'` con tag `[canje:venta_id]` en descripción |

#### `proveedores`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `nombre`, `whatsapp`, `productos`, `notas` |

#### `compras`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `proveedor_id`, `proveedor_nombre` |
| `fecha`, `nota`, `total` |
| `estado` ('pendiente' / 'recibida' / 'cancelada') |

#### `compras_items`
| Campo |
|---|
| `id`, `compra_id`, `prod_id` |
| `nombre`, `qty`, `costo`, `subtotal`, `tipo`, `uds_empaque` |

#### `puntos_clientes`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `nombre`, `whatsapp` (clave de búsqueda) |
| `puntos_saldo`, `puntos_ganados_total`, `puntos_canjeados_total` |
| `total_compras`, `num_pedidos` |
| `ultima_compra`, `ultima_actividad` |

#### `puntos_transacciones`
| Campo |
|---|
| `id`, `id_licencia`, `created_at` |
| `cliente_whatsapp` |
| `tipo` ('acumulacion' / 'canje' / 'devolucion' / 'vencimiento') |
| `puntos`, `saldo_anterior`, `saldo_nuevo` |
| `venta_id` (FK lógico → ventas.id, NO constraint detectado) |
| `valor_venta`, `descripcion`, `registrado_por` |

### 6.2 Volumen actual (datos reales consultados)

| Tabla | Registros |
|---|---|
| ventas | 101 |
| inventario | 91 |
| puntos_transacciones | 75 |
| clientes_frecuentes | 36 |
| puntos_clientes | 31 |
| compras | 10 |
| gastos | 5 |

### 6.3 Datos críticos que viven solo en localStorage (no en DB)

| Llave | Contenido | Implicación |
|---|---|---|
| `lc_cartera_local` | Cuentas por cobrar completas | ⚠️ Si se borra navegador, se pierde |
| `lc_caja_actual` / `lc_caja_historial` | Apertura y cierres de caja | ⚠️ Riesgo de pérdida |
| `lc_cotizaciones` | Cotizaciones | ⚠️ No persiste entre dispositivos |
| `lc_ventas_espera` | Ventas guardadas | ⚠️ |
| `canje_puntos_lacava` | Map de puntos personalizados por producto | ⚠️ |

---

## 7. 🔐 SEGURIDAD

### Lo que existe

| Capa | Implementación |
|---|---|
| Login | Usuario/password **hardcoded en el JS** (`LOGIN_USER='lacava'`, `LOGIN_PASS='cava2026'`) |
| Sesión | localStorage `lcava_session_v1` con TTL 30 días |
| Licencia | Verificación remota vía `licencias` (activo + fecha vence) |
| Service Worker | Cachea recursos same-origin y Google Fonts |
| HTTPS | Forzado por Netlify |

### ⚠️ Riesgos identificados

1. **Credenciales en cliente:** El usuario/contraseña están en texto claro en el HTML. Cualquier persona puede leerlas con "Ver código fuente".
2. **`anon` key de Supabase expuesta:** Visible en el HTML. Sin RLS robusto, da acceso completo a todas las tablas.
3. **Sin RLS detectado:** El anon key actual lee/escribe en cualquier tabla (consultas exitosas sin auth real).
4. **Sin auditoría:** No hay log de quién hizo cada cambio (todos los `registrado_por` son `'pos'`, `'admin'` o `'sistema'`, valores hardcoded).
5. **Sin protección CSRF / rate limiting** propia.
6. **El `showLock()` puede bypasearse** editando `display:none` en DevTools — la verificación es solo cliente.

---

## 8. 🔌 APIS Y CONECTORES

### APIs externas consumidas

| Servicio | Endpoint | Uso |
|---|---|---|
| **Supabase REST** | `https://egjlrcokerffuoqwbxlh.supabase.co/rest/v1/*` | Todas las operaciones CRUD (90+ llamadas en el código) |
| **Google Fonts** | `fonts.googleapis.com` | Plus Jakarta Sans, Playfair Display |
| **Google Sheets** | `docs.google.com/spreadsheets/d/{ID}/export?format=csv` | Importación masiva de inventario (CSV público) |
| **WhatsApp** | `https://wa.me/{numero}?text={mensaje}` | Deep links — sin API oficial |

**No hay webhooks ni callbacks de servicios externos.**

---

## 9. 🔧 VARIABLES DE ENTORNO

**Hallazgo crítico:** Este sistema **no usa variables de entorno**. Todo está hardcoded en el JS:

| Constante (línea) | Propósito | Riesgo si se modifica |
|---|---|---|
| `SB` (1906) | URL del proyecto Supabase | 🔴 Apunta a base equivocada |
| `SK` (1907) | Anon key de Supabase | 🔴 Pierde acceso a la DB |
| `CID` (1908) | Identificador de tenant `'lacava'` | 🔴 Mezcla datos con otro tenant |
| `CAVA_WA` (1909) | WhatsApp 3001785744 | 🟡 Cambia destino de mensajes |
| `LOGIN_USER` / `LOGIN_PASS` (1960-61) | Credenciales | 🔴 Bloquea acceso |
| `PUNTOS_RATIO=800` (1912) | $800 = 1 punto ganado | 🟡 Cambia economía del programa |
| `PUNTOS_VALOR=16` (1913) | 1 punto = $16 al canjear | 🟡 Cambia economía del programa |
| `PUNTOS_MIN_COMPRA=50000` (1914) | Mínimo de compra para acumular | 🟡 |
| `PUNTOS_MIN_CANJE=500` (1915) | Saldo mínimo para canjear | 🟡 |
| `PUNTOS_VENCIMIENTO=180` (1916) | Días para vencimiento de puntos | 🟡 |

---

## 10. 🧱 LÓGICA DE NEGOCIO CRÍTICA

### Reglas de empaque (la más sensible)

- `precio_costo` siempre se almacena **a nivel empaque**
- `stock` es **número de empaques completos**
- `uds_sueltas` son unidades sueltas que **NO completan un empaque**
- Al vender por unidad de un producto con `uds_empaque > 1`:
  - Se calcula `total_uds = stock * uds_empaque + uds_sueltas`
  - Se descuenta `it.qty` del total
  - Se recalcula `stock = floor(restantes / uds_empaque)` y `uds_sueltas = restantes % uds_empaque`

### Reglas de puntos (configurable)

- **NO acumulan puntos:**
  - Ventas a crédito (`estado='credito'`)
  - Ventas con descuento (factura o por item)
  - Ventas sin WhatsApp registrado
  - Ventas por debajo de $50.000
  - Canjes
- **Cálculo de puntos:** `floor(total / 800)`
- **Costo de canje por producto:** `ceil(precio_venta / 16)` (editable manualmente y guardado en `canje_puntos_lacava`)
- **Vencimiento:** 180 días de inactividad → puntos a 0, registra `tipo='vencimiento'`

### Reglas de contabilidad

- **COGS:** sumatoria de `precio_costo * cantidad_vendida` (vía `getVentasRangoSB`)
- **Compras:** NO se restan de la utilidad (inversión en inventario, no gasto). Aparecen como informativo.
- **Canjes:** Generan gasto `Fidelización` con valor = `precio_costo` del producto entregado
- **Ventas con `estado='canje'`:** EXCLUIDAS de cálculos de ingresos y ticket promedio

### Reglas de cartera (CxC)

- Vive 100% en localStorage (`lc_cartera_local`)
- Al eliminar una venta con cartera, se elimina también de cartera
- Al editar una venta con cartera, se recalcula saldo: `total_nuevo - sum(abonos_hist)`
- Abonos se pueden registrar desde módulo Cartera o desde Editar Venta

### Reglas de caja

- Solo se permite **una caja abierta a la vez**
- Al cerrar, ventas del turno = `VENTAS_MES.filter(v => v.created_at >= CAJA_ACTUAL.fecha_apertura)`
- Esperado efectivo = `efectivo_inicial + sum(ventas_efectivo)`
- Esperado banco = `banco_inicial + sum(ventas_transferencia + nequi + daviplata)`
- Cierres NO se pueden eliminar, solo corregir (los valores reales)
- Historial limitado a 90 registros (rotación FIFO)

---

## 11. ⚠️ DEUDA TÉCNICA

### Críticas

1. **4 copias del mismo archivo a sincronizar manualmente** → ya causó bugs históricos. La sincronización es por `Copy-Item` PowerShell sin verificación.
2. **Archivo monolítico de 500KB** → carga lenta en móvil. Sin code splitting posible (no hay build).
3. **`anon` key con acceso total a la DB** sin RLS → riesgo de exfiltración o manipulación masiva de datos.
4. **Cartera, cotizaciones, caja viven en localStorage** → un usuario en otro dispositivo no ve nada. Si se borra cache, se pierden.
5. **Sin tests** de ninguna clase.
6. **Sin migraciones versionadas** del esquema de DB.

### Importantes

7. **Cliente expuesto** — Login hardcoded en HTML.
8. **Service Worker cachea HTML** — ya generó problemas de versiones viejas. Sin estrategia de bust.
9. **Conflicto de funciones:** `guardarNuevoProd` definida 2 veces (línea 3305 y 4297), `addItemCompra` 2 veces (3635 y 4422), `aplicarCompraInventario` 2 veces (3713 y 4478). La segunda definición gana — código muerto.
10. **`getVentasRangoSB` empareja por substring del nombre** (línea 4080) → puede equivocarse de producto si dos tienen nombres similares.
11. **Top productos en Reportes** hace queries en lotes de 50 IDs → con muchas ventas, varios round-trips secuenciales.

### Menores

12. Hay barras escapadas mal en el código original (`\rest\v1\`) en algunos lugares — funciona en JS por coincidencia (interpretan como `/rest/v1/`).
13. Algunas funciones combinan render + lógica de negocio (`renderVentasList` filtra y muestra).
14. CSS y JS conviven en un solo archivo HTML sin separación.

---

## 12. 🎯 MAPA DE IMPACTO

Si modificas **X**, podría afectar:

| Si tocas... | Verifica también |
|---|---|
| **`addP()` / `chgQty()`** | POS, cart, descuento por item, stock, picker de empaque |
| **`doVenta()`** | Ventas, Cartera, Puntos, Stock, Clientes frecuentes, Caja |
| **`PUNTOS_RATIO` o `PUNTOS_VALOR`** | Puntos calculados en doVenta, costo de canje, reglas, ejemplos en pestaña Reglas, valor mostrado en cards |
| **`cargarInventarioSB()`** | POS, Inventario, Reportes, Catálogo, Compras |
| **`renderEstadoResultados()`** | Cards de contabilidad, formula de utilidad |
| **`actualizarStockSB()`** | Stock visible en POS, Inventario, alertas |
| **Esquema `ventas`** | doVenta, abrirEditarVenta, eliminarVenta, Reportes, Cartera (la mira por id), Caja (cálculo turno) |
| **Esquema `inventario`** | TODO el sistema |
| **`localStorage` keys** | Cartera, Cotizaciones, Caja, Ventas en espera, Canje custom |
| **Service Worker** | Versiones cacheadas (cambiar `CACHE = 'lacava-v1'` para forzar invalidación) |
| **`_redirects`** | Comportamiento de la raíz `/` en Netlify |
| **`uds_empaque`** | Todo el sistema de cálculo de stock, precios por unidad, restauración al eliminar venta |

---

## 13. ✅ RECOMENDACIONES

### Partes seguras de modificar (🟢)
- HTML/CSS de presentación (siempre y cuando se mantengan los `id` que usa el JS)
- Vistas que solo leen (`Reportes`, `Resumen`, `Métricas de Puntos`, `Ranking`)
- Pestaña `Reglas` (es solo informativa)
- Catálogo público (`catalogo.html`) — está aislado del dashboard
- Textos, labels, emojis

### Partes que requieren máxima precaución (🔴)
- `doVenta()` y todo el flujo POS
- `eliminarVenta()` (revierte stock + cartera + puntos)
- `guardarEdicionVenta()` (recalcula puntos, stock, cartera)
- `confirmarCanje()` y `revertirCanje()` (cuádruple efecto: puntos + inventario + venta + gasto)
- Funciones de cálculo de empaque (`addP`, `chgQty`)
- `confirmarCierreCaja()` (crea registro histórico)
- `actualizarStockSB()` (cualquier corrupción afecta toda la cadena)

### Refactor recomendado (mediano/largo plazo)
1. **Separar JS del HTML** en archivos `.js` modulares
2. **Migrar Cartera/Cotizaciones/Caja a Supabase** para multi-dispositivo y persistencia
3. **Migrar autenticación a Supabase Auth** con RLS por `id_licencia`
4. **Configurar RLS en todas las tablas**
5. **Eliminar duplicados de archivos** — usar Netlify build con un solo source
6. **Versionado de Service Worker** automático (basado en hash de archivo)
7. **Eliminar funciones duplicadas** (`guardarNuevoProd`, `addItemCompra`, etc.)

### Documentación faltante (recomendado documentar mejor)
- Estados posibles del campo `ventas.estado`
- Flujo completo de empaques (mejor en un README dedicado)
- Estructura exacta de las entradas en `lc_cartera_local`
- Endpoints de Supabase que se consumen (con ejemplo de payload)
- Cómo agregar un nuevo tenant (`CID`)

---

## 14. 📝 NOTAS DE LA AUDITORÍA

**Información que NO pudo verificarse desde el código:**
- ❌ Configuración real de **Row Level Security** en Supabase — no es inspeccionable desde el cliente. **Acción sugerida:** revisar manualmente en el panel de Supabase.
- ❌ Existencia de **triggers o functions** en Postgres — no observables vía REST API. **Acción sugerida:** revisar en Supabase → Database → Functions/Triggers.
- ❌ **Constraints e índices** de las tablas — no expuestos por PostgREST. **Acción sugerida:** revisar en Supabase → Database → Tables.
- ❌ Estructura de `detalle_ventas` confirmada solo por inferencia desde el código que la inserta (no había datos en la tabla al momento de inspección).
- ❌ Variables de entorno en Netlify — no inspeccionables sin acceso al panel.
- ❌ Configuración de GitHub Actions o automatizaciones — no observados archivos `.github/`.

**Estado de los archivos al cierre de auditoría:** los 4 dashboards están sincronizados (mismo hash MD5). El repo Git tiene cambios sin commitear de toda la sesión actual.

---

## 📌 ADENDA: SESIÓN DE TRABAJO 2026-05-20 / 2026-05-29

Cambios funcionales más importantes implementados en las últimas sesiones (referencia rápida para próximas iteraciones):

1. **Bug del cálculo de puntos en canjes** — corregido. Ahora usa `precio_venta / PUNTOS_VALOR` (16) en vez de `/ PUNTOS_RATIO` (800).
2. **Bug contable de compras** — corregido. Compras ya NO se restan de la utilidad neta.
3. **Top 10 productos en Reportes** — corregido. Ahora añade `estado` al select y hace queries en lotes de 50 IDs.
4. **Layout de Caja/Cotizaciones/Cartera** — corregido. Vistas movidas dentro de `<main>` (antes quedaban fuera).
5. **Pestaña Historial de canjes** — creada. Con botón Revertir que devuelve puntos + reintegra inventario + reversa contabilidad.
6. **Confirmación de venta** — añadida antes de doVenta() (modal de revisión).
7. **Corrección de cierres de caja** — añadida sin opción de eliminar (solo modificar reales).
8. **Calculadora de cambio en POS** — añadida cuando método de pago = efectivo.
9. **Carrito POS** — ampliado de 290px a 360px y hecho scrollable.
10. **Alertas de caja en POS** — añadidas (primer ingreso del día / caja del día anterior sin cerrar).

---

*Fin de la auditoría técnica. Mantenga este documento sincronizado con cambios estructurales relevantes del sistema.*
