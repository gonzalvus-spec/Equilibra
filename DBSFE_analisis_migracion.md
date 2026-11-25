# Análisis de Ingeniería Inversa — DBSFE / SIADI (VFP 9)

**Fecha:** 2026-11-18 · **Origen:** `C:\Users\gonza\OneDrive\Desktop\DBSFE` · **Modo:** solo lectura (ningún archivo fue modificado; scripts temporales en `%TEMP%\opencode`)

---

## FASE 1 — Inventario y diagnóstico de artefactos

### 1.1 Panorama general

- `DBSFE\DBSFE\` — **512 archivos, 118.13 MB**. Un `DBSFE.zip` (~29.5 MB) existía al inicio del análisis y desapareció durante el mismo (posible des-sincronización de OneDrive); no se pudo inventariar su contenido.
- Estructura: raíz (ejecutables + configuración) + `formatos/` (reportes FRX + plantillas), `salida/` (PDFs emitidos + copia de trabajo de la BD en `salida\temp`), `xls/` (plantillas Excel), `certificado\20514598224\` (certificados PFX), `aduanas/` (vacía).
- **Es la carpeta de instalación de una aplicación VFP9 en producción**, no un repositorio fuente. El ERP real vive en `\servidor\...` (referenciado como `c:\estsfe` en `FRX2Any.ERR`) y su código fuente NO está en esta carpeta.

### 1.2 Clasificación por extensión (512 archivos)

| Grupo | Extensiones | N° | Observaciones |
|---|---|---|---|
| Datos e índices | `.dbf` | **151** | ~101,585 registros, ~38.7 MB de datos; VFP header `0x30`; `_NullFlags` (M/I/N nulos) |
| | `.fpt` | 3 | `reg.FPT` 31.7 MB, `gre.FPT` 9 KB, `FOXUSER.FPT` 158 KB |
| | `.cdx` | 4 | Solo tablas raíz: `defbase`, `defrepor`, `cias`, `estacion` |
| | `.tmp` | 8 | Pares DBF/FPT (`1KW1000H/I/K/L/N/O/Q/R.TMP`) — artefactos binarios de reportes |
| | `.bak` | 5 | Copias TS/backup de `cias`, `defbase`, `defrepor`, `estacion`, `SFE0522` |
| Código fuente | `.prg` | **2** | `SFE0522.PRG` (2,819 l.) y `formatos\sfe0488.PRG` (2,750 l.) — **solo librería de reportes/email/API GRE** |
| | `.fxp` | 2 | Compilados de los mismos dos PRG |
| | `.prg`/`.h`/`.mpr`/`.qpr` del ERP | **0** | **No existen** |
| Interfaces | `.scx`/`.sct` | **0** | **Sin formularios fuente** |
| | `.vcx`/`.vct` | 1 | `frx2any.vcx` + `.vct` (1.67 MB) — **librería de terceros** FRX2Any (FRX→PDF/XLS/HTML/Word/RTF/Image/XML y visor/email) |
| | `.frx`/`.frt` | **53** pares | Reportes CPE y de gestión (representación impresa) |
| | `.mnx`/`.mpr`/`.qpr` | 0 | Sin menús |
| Binarios/Ejecutables | `.exe` | 11 | `siadi.exe` (×3 variantes iguales 1.88 MB), `actexe.exe`/`actexe1.exe` (actualizador 51 KB), `serie.exe`, `PKZIP/PKUNZIP.EXE`, `RegAsm.exe`, **`VFPsFirmaCPE.exe`** (.NET), **`VFPsPDF417.exe`** (.NET) |
| | `.dll` | 10 | `vfp9*.dll` (runtime VFP9 ESN/DEU/ENU + vfp9r/vfp9t), **`VFPFirmaXML.dll`** (.NET, firma CPE), `BarCodeLibrary.dll` (nativo 32-bit), `iSEDQuickPDF.dll` (QuickPDF ActiveX nativo, 1.39 MB), `XZip.dll` (zip CDR) |
| | `.fll` | 2 | `foxcrypt.fll` / `FoxCrypto.fll` (cifrado VFP, 290 KB) |
| | `.app` | 2 | `jsonfox.app` (JSONFox, parseo JSON vía COM), `PDFfile.App` (FRX→PDF stand-alone) |
| Configuración y externos | certificados | **3** `.pfx` | `certificado.pfx`, `llave2023.pfx`, `llave2025.pfx` (RUC 20514598224) |
| | `.ini` / `config.fpw` / `.xml` UBL | — / — / 2 | `response.txt` / `response.xml` = CDR SUNAT SOAP (base64+zip); `ticket_baja.xml` = sendSummaryResponse (ticket 1615912723651); `temp.txt` = muestra UBL 2.1 CreditNote F001-7 firmada rsa-sha1 |
| | `.xml`/`.json` otros | 1 (`ticket_baja.xml`) | JSON solo generado en runtime (`aduanas\fac_ele\body.json` — ausente) |
| Salida/Output | `.pdf` | **166** | 2 facturas `20514598224-01-F001-2248/2249.pdf`, 1 GRE `...-09-T002-174.pdf`, 163 `GRET001xxx.pdf` (guía remisión transpor.); 3 PDFs <2 KB (974–1032 B) = probables errores |
| | `.xlsx`/`.xls` | 23 | Plantillas de reportes Excel (rgv, rdd, rpc, rcc, rcd, rce, cnn, cta, che, che0000, che0000.xls, che0000.xlsx, che0000.xls, rdd0000, rgd0000, rpc0000, rcc0000, rcd0000, rce0000, rgc0000, rdv0000, registrocnn, che0000... ver `xls/`) |
| Soporte | `.ico`/`.jpg`/`.png`/`.db` | 6 | `andes.ico`, `logorobinson*.jpg/png`, `FERREVILAX.jpg`, `Thumbs.db` ×2 |
| | `.err`/`.txt` | 4 | `FRX2Any.ERR`, `sfe0522.ERR`, `temp.txt`, `response.txt` |

### 1.3 ¿El código fuente está expuesto o solo binarios?

**Parcialmente — y la parte crítica NO lo está.**

- **Sí en texto plano (CP1252/ANSI):** `SFE0522.PRG` y `formatos\sfe0488.PRG` son fuente VFP legible. Pero son una **librería parcial**: funciones de exportación a Excel vía COM (`createobject("Excel.Application")`), correos vía Outlook COM, envío/consulta de **Guías de Remisión Electrónica (GRE)** por API REST del proveedor `https://apiandes.andessystems.com` con **JWT codificado en el código fuente**. Ninguna de las dos variantes incluye facturación/boletas/notas, numeración, cálculo de IGV ni firma digital.
- **No recuperable directamente:** formularios (`.scx`), menús, clases del ERP, motor de facturación (numeración F001/B001/T001/T002, catálogos SUNAT por serie en `ser.DBF`), firma CPE, integración SOAP SUNAT — todo ello está compilado en **`siadi.exe`** (1.88 MB, VFP9) y en `actexe.exe`. Las `.ERR` confirman errores VFP con rutas `c:\estsfe\`.
- **Nada de proyecto VFP:** sin `.pjx/.pjt`, `.dbc`, `.mnx`, ni cabeceras `.h`. Los `.FXP` son compilados de los dos PRG accesibles.
- **Las dos versiones divergen:** `sfe0488.PRG` (04.88, más antiguo) contiene `libroventas_general`, `libroventas_simplificado`, `impo_doc_sisex`, `genera_reco`, `grgxls`, `envia_email_gre_outlook` que NO están en `SFE0522.PRG`; `SFE0522.PRG` (05.22, más nuevo) añade `GRETICKET` (INSERT/UPDATE) y comentarios "GRE — 2023". Ninguna es el maestro completo.
- `frx2any.vcx` es de **terceros** (FRX2Any) y sí está legible (métodos VFP en texto en el memo `METHODS`) — define las clases `pdffile`, `excelfile`, `htmlfile`, `wordfile`, `rtffile`, `previewfile`, `imagefile`, `xmlfile` + `outputoptions` (formulario de opciones). Su pipeline depende de **GDI+ de 32 bits** (`gdiplus.vcx`, faltante según `FRX2Any.ERR`) y de `iSEDQuickPDF.dll` (ActiveX nativo).

**Conclusión Fase 1:** lo recuperable como fuente es ≈ **5,600 líneas de funciones auxiliares** que referencian globales inexistentes (`crutasit`, `curgen`, `vcod`, `wfen_doc`, funciones `damedato`, `fechasql`, `decodifica`, `ttod`, `dma`, `cmonth`, `closdata`…). **Se requiere reconstrucción/reescritura del 85–90 % de la lógica.** El `.exe` puede descompilarse parcialmente (VFP decompilers extraen P-code; la fidelidad de nombres/estructura es limitada) — estrategia: *clean-room rewrite* guiado por esquema de datos + FRX + documentación visible.

### 1.4 Identificación del sistema y la instalación

- **Producto:** `SIADI` / `E-SIADI` — sistema ERP + facturación electrónica de **Andes Systems E.I.R.L.** (RUC 20513233605, Callao). Carpeta de instalación referenciada: `C:\estsfe` (ausente).
- **Cliente/instalación:** **Robinson Marine Electronics S.R.L.** (RUC **20514598224**), Callao — rubro aduanas/agencia de carga y electrónica marina ("EQUIPOS ELECTRÓNICOS PARA EMBARCACIONES / VENTAS,POST VENTAS,SERVICIO,REPUESTO", `robinsonperu@robinsonme.com.pe`, logos `logorobinson*.jpg/png`). Logos `FERREVILAX.jpg` → plantillas reutilizadas de otros clientes (multi-tenant por `COD_INTER` / serie).
- **Versión:** `siadi 21.04.exe` (misma talla que `siadi.exe`) ⇒ build 21.04. `SFE0522` ⇒ formato 0522 (serie de reportes del cliente). `sfe0488` ⇒ 04.88.
- **Arquitectura cliente-servidor:** VFP9 32-bit + backend **SQL Server remoto vía `SQLEXEC(cnbases, …)`** (ODBC/OLEDB). En `cias.DBF`: `IP_SQL`, `USUARIOSQL`, `CLAVESQL`, `PREFIJO`. Los DBFs locales son cachés/áreas de trabajo, **no** la BD maestra. Evidencia: `SQLEXEC(cnbases,'select * from CHD','chd')`, `UPDATE GRE …`, `INSERT INTO GRETICKET …`.
- **Serie de impresión:** F001 (facturas), B001 (boletas y NDC — ver `ser.DBF`), F001/B001 (notas), T001/T002 (guías remisión remitente, tipo 09), GRT/T00x (transportista, tipo 31), CDR (comprobante retención 20), CDP? etc.

---

## FASE 2 — Ingeniería inversa de datos y dominio

### 2.1 Estructura física de los DBF

- Cabecera `0x30` (VFP); registros con `_NullFlags` (campo tipo `0`, 14 tablas lo tienen). Sin `.dbc` ⇒ **sin constraints, PK/FK ni triggers declarativos**: la integridad vive solo en el código compilado.
- Tipos VFP usados: `C` (1,291 campos), `N` (441), `I` enteros (138), `T` DateTime OLE (137, double, epoch 1899-12-30), `D` (14), `M` memo (5), `L` (7), `G` general (1: `reg.FORM_PDF`), `0` null-flags (14).
- Texto en ANSI (compatible CP1252/CP850; bytes `0xC9`=É, `0xD1`=Ñ coinciden en ambas; VFP gana). **ETL debe decodificar CP1252 y fallar limpio.**
- `salida\temp\*.DBF` = instantáneas de trabajo (`SELECT … INTO CURSOR/DBF`) regeneradas por el ERP; contienen datos reales (p. ej. `reg.DBF` 2,465 documentos, `det.DBF` 9,743 líneas, `gre.DBF` 1,013 guías, `cam.DBF` 20,365 tipos de cambio desde 1990, `ta086.DBF` 49,022 códigos **UNSPSC**).

### 2.2 Tablas principales (esquema resumido, `salida\temp`)

| Tabla | Reg. | Rol | Claves/observaciones |
|---|---|---|---|
| `reg.DBF` | 2,465 | **Cabecera de documentos de venta** (FAC/BOL/NDC/NDD/COB/LET) | PK lógica `N_DOC+TIPO_DOC+SUCURSAL`; ~130 campos; doble moneda SOL/USD/_ORI; `XML` memo (UBL embebido), `HASH1`, `STATUS/DES_STATUS` SUNAT, `TICKET_API`, `QR_SUNAT`, `DETRA*` (detracciones), `NRO_DETRA`, percepción/retención; logística marítima (`BOOKING`, `NAVE`, `PTO_ORIGEN/DESTI/FINAL`, `HBL`, `N_CNT*`, `PRECINTO*`); aduanas (`AGE_ADU`, `EMBARCADOX`, `AGTE_CARGA`) |
| `det.DBF` | 9,743 | Líneas de documento | `N_DOC/TIPO_DOC/SUCURSAL` + `ITEM`; `COD_CON`→`ta071/ta086` UNSPSC; `COD_SUNAT`; IGV por línea (`TIPO_IGV`→`ta077`), `COD_DSCTO`→`ta087`; cantidades/pesos aduaneros |
| `grd.DBF` | 4,684 | Líneas de **guías de remisión** | Similar + `SUBPARTIDA` (arancelaria), `NUM_DAM`, `PAQUETES`, `POCISION` (DAM/manifiesto) |
| `gre.DBF` | 1,013 | **Cabecera guía remitente/transportista** | `XML` memo, `STATUS/DES_STATUS`, `MOT_TRAS`→catálogo motivos, `UBIGEO_LLE/PAR`, `RUC_TRANS`, `LIC_TRANS`, `PLACA*`, `TIPO_VIA` (puerto→`gre63/gre64`), `PUERTO`, `N_CNT*`/`PRECINTO*`, `INDI_*` (extras c/SUNAT GRE), `REMITENTE/PAGADOR/SUBCONTRA`, `XML`/`HASH1`/`QR_SUNAT`/`TICKET_API` |
| `gredoc.DBF` | 0 (estr.) | Documentos relacionados GRE | `TTIPO_DOC/TN_DOC/RUC` → `GRE61` (catálogo docs) |
| `greticket.DBF` | 1,079 | **Tickets SUNAT GRE** (async) | `TICKET_API`, `QR_SUNAT`, `ERROR_SUNAT`, `FECHA` |
| `gre61..65.DBF` | 26/13/21/31/97 | Catálogos GRE SUNAT | 61=docs relacionados, 62=?, 63=puertos marítimos (UBIGEO), 64=puertos terrestres, 65=? |
| `areg.DBF` | 3,604 | Registro/auditoría documentos (¿compras?) | similar a `reg` |
| `cnn.DBF` | 89 | **Clientes** | clave `N_DOC` (RUC/DNI/CEX), `EJECUTIVO`, `CRED/LINEA_CRED`, `PERCEPCION`, `BD_FE` |
| `per.DBF` | 6 | **Usuarios** — **contraseñas en claro** (`CLAVE`) | `TIPO_USER='S'`; emails @robinsonme.com.pe |
| `ser.DBF` | 7 | Series por tipo doc/sucursal | F001/B001/T001/T002 + `FORMATO='2'` + `TIPO_IGV` |
| `cam.DBF` | 20,365 | Tipo de cambio histórico (COMPRA/VENTA/XEU) | serie desde 1990 → reemplazable por API SBS/SUNAT |
| `pcg.DBF` | 2,006 | **Plan contable** (9 díg. + `SUNAT` I = cuenta 12 dígitos?) | `DEBE/HABER`, `C_BAL`, `C_COSTOS`, `TIPO_ANEXO` ('T'=?, 'C'=cta) |
| `cfc.DBF` | 1,296 | Cuotas por cobrar (cronograma) | `N_DOC/TIPO_DOC/ITEM/FCH_CUOTA/OTOTAL` |
| `ccf.DBF` | 53 | **Cuentas fijas contables** | 776/676/40111… (dif. cambio, redondeo, IGV cuenta propia) |
| `cdc.DBF` | 4 | Conceptos costos | 911/799 (costos operativos/administrativos) |
| `cie./cfe.DBF` | 89 | **Textos de ayuda por campo** (módulo FAC) | `CONCEPTO`→`OBJETO` (control del form: `txtF19`, `cmbbase1`, `cmbbase2`…) — **pista de la estructura de la UI VFP** |
| `can.DBF` | 16 | Cierres contables anuales 2005–2020 | `FCIERRE` |
| `red.DBF` | 17 | **Retenciones SUNAT** (tipo 20, 2016–2017) | `R001x`, `TN_DOC`, `T_RETE_SOL` |
| `conductores.DBF` / `vehiculos.DBF` | 21 / 8 | Maestro choferes (licencia) y flota | MTC: `N_AUT_TRAN`, `ENT_AUTO` (en `ta024`) |
| `ta086.DBF` | **49,022** | **UNSPSC** (código 8 díg. + descripción) | `CODIGO`/`DESCRIP` — catálogo de productos |
| `ta005.DBF` | 1,874 | **Ubigeo 2005** (distrito/prov/dpto) | `CODIGO` 6 díg. |
| `ta043.DBF` | 57 | Catálogo 01 SUNAT (tipo doc CPE) | incluye `DES_VARIOS` (pantalla multi-doc) |
| `ta077.DBF` | 16 | Catálogo 07 (tipo afectación IGV) |  |
| `ta087.DBF` | 22 | Catálogo 53/54 (cargos/descuentos) |  |
| `ta033.DBF` | 863 | Feriados/calendario laboral |  |
| `ta037.DBF` | 266 | Catálogo SUNAT países con vigencia | `FINICIO/FFIN` |
| `ta020.DBF` | 196 | IATA aeropuertos | `CODIGO/CIUDAD/NOMBRE/KM` |
| `ta026.DBF` | 20 | Catálogo 59 (formas/medios de pago) |  |
| `ta024.DBF` | 9 | **Empresas de transporte** (con `N_AUT_TRAN`, `ENT_AUTO`, `MTC_TRANS`) | mezcla clientes transporte + MTC |
| `ta053.DBF` | 56 | Monedas + factor conversión (2012) | reemplazable por servicio SBS |
| `ta061.DBF` | 268 | Países ISO + especiales |  |
| `ta057.DBF` | 311 | Infracciones aduaneras (100–300) |  |
| `ta060.DBF` | 15 | Tipo emisión ORIGEN/DESTINO/HOLD |  |
| `ta063.DBF` | 36 | Productos bolsa/commodities | azúcar/alcohol/hidrobiológicos |
| `ta071.DBF` | 10 | **Catálogo ítems/conceptos de venta** con precio | `CODIGO` 8 díg., `COD_SUNAT`, `COD_GUIA`, `TIPO_UNI` |
| `ta072.DBF` | 82 | Motivos de ingreso/egreso a banco/caja | `TIPO` I/E, `CUENTA`, `TIPO_GRID` |
| `ta042.DBF` | 33 | Tipos de asiento (facturas/NDC/NDD…) |  |
| `ta051/052/054/055/058/059/062/064/066/068/070/073/076/078/079/081/082/083/084/085/087` | 1–268 | SUNAT / catálogos varios |  |
| `defbase.DBF`/`defrepor.DBF` | 94 c/u | **Catálogo de formatos de reporte** (`COD`→`FORMATO='0522'`, `DESCRIPCIO`, `REGXHOJA`, `CARXREG`) | 94 reportes (RGD/RPC/RCC/RCD/RCE/RNC/RND/RCS/REG/LDR/PCG/LID/LMY/BDC/LCB/BGE/estaciones/certificados…) |
| `estacion.DBF` | 1 | **Estación de trabajo** | series (FAC/BOL/NDC/NDD/GRE/CDR/TKT/GRT), `EMAIL_SCHE`, printer, AnyDesk, PVENTA |
| `cias.DBF` | 1 | **Maestro de empresa/estación global** | `RUC`, `USER_FE/CLAVE_FE/GMAIL_FE/CGMAIL_FE/CLAVE_DIGI` (credenciales FE en claro), `IP_SQL/USUARIOSQL/CLAVESQL`, `SERVER_AWS`, `TC_VENTA`, `CTA_DETRA`, `REGIS_MTC`, `RUTA_SIT` |
| `FOXUSER.DBF` | 228 | Recurso VFP (teclas/macros) | descartable |
| `acnn.DBF` | 148 | Auditoría clientes |  |
| `arrc.DBF`/`arc…` | 0 | Vacías |  |

**Total:** 151 tablas, 101,585 registros, ~38.7 MB. **Volumen transaccional real: bajo** (2,465 documentos de venta; 1,013 guías; 94 reportes).

### 2.3 Relaciones implícitas (sin .dbc)

```
reg (N_DOC,TIPO_DOC,SUCURSAL) 1───N det (…,ITEM)
reg                       1───N cfc (cuotas, por N_DOC/TIPO_DOC)
reg                       1───N reg.XML memo (CDR embebido)
cie (documentos aduanas: reg.HBL/MBL/BOOKING/N_CNT/…) ⊂ reg
gre (N_DOC,TIPO_DOC,SUCURSAL) 1───N grd(…,ITEM)
gre                       1───N gredoc (N_DOC/TIPO_DOC ↔ TTIPO_DOC/TN_DOC)
gre                       1───N greticket (TICKET_API / QR_SUNAT)
cnn.N_DOC ── clientes → reg.RUC (lookup por damedato("cnn",…))
ser.SERIE por TIPO_DOC/SUCURSAL        pcg (plan contable) → ccf/cdc/ccc
ta043 (tipo doc) · ta005 (ubigeo) · ta077/078/087 (IGV/cargos) · ta086 (UNSPSC)
esta.DBF (series/estación) → cias.DBF (empresa) → formato 0522
```

Índices físicos (`.cdx`): solo 4 (`cias`, `defbase`, `defrepor`, `estacion`). En `salida\temp` **no hay `.cdx`** ⇒ se indexan en memoria (`INDEX ON` sobre cursores). Regla práctica de migración: generar PKs sobre `(n_doc, tipo_doc, sucursal[, item])` y FKs lógicas `reg.ruc → cnn.n_doc`, `det.cod_con → ta071.codigo`, `reg.tipo_doc → ta043.codigo`, `reg.ubigeo → ta005.codigo`, y `gre.ruc_trans → ta024.n_doc`.

### 2.4 Módulos del sistema (evidencia combinada: nombres, catálogos, reportes)

| Módulo | Evidencia |
|---|---|
| **Ventas / Facturación electrónica (CPE)** | `ser.DBF`, `fac0522/BOL0522/NDC0522/NDD0522.FRX`, `RES/REV/XML/CDR/CDB/RCR` (catálogo `defbase`), `temp.txt` UBL CreditNote, `response.txt/xml` CDR SUNAT SOAP (`sendBill/getStatus`), `ticket_baja.xml` (sendSummary), `rnd/rnc/rgd/rpc/rcc/rcd/rce/rdv/rdd/reg` exports, `SFE0522.PRG::envia_email_fe_outlook()` |
| **Guía de Remisión Electrónica (GRE rem/trans)** | `gre.FRX`, `gre.DBF/grd/gredoc/greticket`, `genera_envia_gre_api()`/`consulta_gre_api()` (API REST proveedor con JWT), `GRE61–65` catálogos, `conductores/vehiculos`, `ta024` (transportistas MTC), PDFs `GRET00x` y `...-09-T002-xxx.pdf` |
| **Compras / Retenciones / Detracciones** | `areg`, `red`, `reg.DETRA*`, `NRO_DETRA`, `OPER_DETRA/BIEN_DETRA/PORC_DETRA`, reporte `RCS` (registro compras SUNAT) |
| **Cuentas por cobrar/pagar** | `cfc` (cuotas), `rpc/rcc/rcd/rce/rdv` (reportes), `sfe0488.PRG`, `DF_PAGO`, `FCH_VENCE` |
| **Bancos / Cheques / Caja** | `che.FRX/chq/tmp`, `che0000.xls`, `che` (reportes por banco, diferidos, anexos, vouchers), `ta056`, `ta072` |
| **Contabilidad / Plan contable** | `pcg` (2,006 cta), `ccf/cdc`, `LID/LMY/LCB/BDC/BGE/320/031/LCB`, `SFE0488:libroventas_general/simplificado`, `ASV/ASC/ASB/ASN/ACR` (asientos), `PCG` reporte |
| **Aduanas / Comercio exterior** | Módulo dedicado (`aduanas/` vacía): DUA (`FCH_ENT_BI`, `NUM_DAM`, `SUBPARTIDA`), HBL/MBL/BOOKING/NAVE/contenedores/precintos en `reg/grd/det`, infracciones `ta057`, puertos `ta020/gre63/gre64`, aeropuertos, `ta060`, agentes (`AGE_ADU`, `AGTE_CARGA`) |
| **Inventario / Catálogos** | `ta086` UNSPSC 49k, `ta063` commodities, `ta071` ítems venta+precio, `ta070`? , lotes (`LOTE`), tara, pesos |
| **Facturación SUNAT retenciones (CDR)** | tipo serie CDR en `estacion.DBF`, reporte `RDR/RDA` (retenciones) |
| **Comunicación electrónica (SUNAT SOAP + REST proveedor)** | `response.txt/xml`, `ticket_baja.xml`, `VFPsFirmaCPE.exe` (.NET — firma), `VFPFirmaXML.dll` (.NET, COM interop via `RegAsm`), `XZip.dll` (CDR), `iSEDQuickPDF.dll`, `BarCodeLibrary.dll` |
| **RRHH / Seguridad** | `per.DBF` usuarios + `CLAVE` en claro; `estacion.DBF` AnyDesk/series; auditoría `acnn` |
| **Reportes / BI** | 94 formatos en `defbase/defrepor` + 53 FRX + 23 XLS plantillas; export Excel COM |

### 2.5 Estado SUNAT de la instalación

- **Numeración/CPE 2.0:** el `temp.txt` (Credit Note F001-7, 17/03/2021) muestra firma `rsa-sha1` → formato legado SHA-1 ya **no admitido por SUNAT** (exige SHA-256). `PFX` en `certificado\20514598224\` (posible cert actual vigente).
- **Dos canales:** (a) SOAP directo a SUNAT (`sendBill`/`sendSummary`/`getStatus`) — facturas/boletas/notas/resumen; (b) REST del proveedor `apiandes.andessystems.com` con JWT — **solo para GRE**. El CDR y el ticket son consistentes (ticket 1615912723651 tipo RA, respuesta 2016).
- **JWT hardcodeado:** `token="Bearer eyJ0eXAi…"` repetido 6 veces en `SFE0522.PRG`; `iat` 1732895593 (2024-11-30), `exp` **1764431593 (≈ 2025-11-29)** → hoy (2026-11) está **expirado**. Debe renovarse/rotarse.

---

## FASE 3 — Viabilidad y arquitectura destino (Tauri + Rust)

### 3.1 Nivel de viabilidad de migración

| Categoría | % est. | Detalle |
|---|---|---|
| **Recuperable directo** (port/1:1) | **≈ 10 %** | Esquema/datos DBF (estructura y registros), catálogos SUNAT (`ta0xx`, `gre61-65`) — migrables a SQLite con ETL; layout de los 53 FRX (como especificación visual de PDF); mapeo de plantillas Excel; catálogo `defbase` (94 reportes) |
| **Reimplementable con referencia** (lógica visible) | **≈ 20 %** | Cliente GRE REST (payload JSON completo verificado en código), `envia_email_fe_outlook` (plantilla HTML del correo a cliente), exports Excel/reportes de gestión (patrón documentado), pipeline FRX→PDF (via terceros → reemplazable por Typst/HTML→PDF), parseo JSON (JSONFox→`serde_json`) |
| **A reconstruir** (en binarios/fuente ausente) | **≈ 70 %** | UI completa (React), motor de facturación (numeración por serie, IGV/percepción/retención/detracción, redondeo), generación/firma UBL CPE (actualmente `VFPsFirmaCPE.exe`/`VFPFirmaXML.dll`), integración SOAP SUNAT, consultas/lógica del ERP sobre SQL Server, cierres contables, integración Outlook/Excel COM, seguridad |

**Viabilidad global: 30–35 % de la funcionalidad puede entregarse rápidamente reusando artefactos; el 65–70 % requiere desarrollo nuevo.** No es un "port", es un **reemplazo con paridad funcional por módulo**.

### 3.2 Base de datos destino

**Opción recomendada: SQLite embebido (vía `sqlx` o `rusqlite`) para la instancia desktop + acceso opcional a SQL Server durante la transición.**

- Los volúmenes (< 200 MB) y la topología (una estación/una empresa, multi-sucursal bajo `SUCURSAL`) encajan en SQLite; la operación actual es mono-usuario por estación. Si se busca consolidar varias estaciones: **PostgreSQL** (esquema idéntico, `sqlx` con feature `postgres`) — misma capa de acceso.
- **Mapeo VFP → SQL:**

| VFP | SQLite | Notas |
|---|---|---|
| `C(n)` | `TEXT` | trim; preservar CP1252→UTF-8 |
| `N(n,d)` | `NUMERIC(n,d)` (o `TEXT` para montos grandes) | decimales exactos; IGV/montos 2 dp; tipo cambio 4 dp (`N(10,4)`); `N(13,2)`→`NUMERIC(18,6)` seguro |
| `I` | `INTEGER` | `ANULADO/IMPRESO/ESTADO` 0/1 → `BOOLEAN` opcional |
| `T` (OLE datetime) | `TEXT` ISO-8601 o `INTEGER` (segundos) | VFP epoch 1899-12-30 + double días → convertir en ETL |
| `D` | `TEXT` ISO-8601 `YYYY-MM-DD` | |
| `L` | `INTEGER` 0/1 | |
| `M` (memo) | `TEXT` | `reg.XML` (UBL), `reg.HASH2`, `gre.XML` — GZIP opcional |
| `G` (general) | `BLOB` | `reg.FORM_PDF` |
| `_NullFlags` | `NULL` nativo | |

- **ETL:** script único en **Rust** (`rust_xlsxwriter` no; usar `dbase`/`calamine` crate o `pyo3`) o en **Python** (`dbfread`, ya probado en este análisis) que: lea con `encoding='cp1252'`; normalice nombres a `snake_case`; cree esquema con PKs `(n_doc, tipo_doc, sucursal[, item])`; descomprima memos; convierta `T`→ISO; cargue vía `INSERT` por lotes; reporte filas/issues (duplicados `N_DOC` sin `TIPO_DOC`, fechas fuera de rango, importes negativos en `anulate`).
- La **BD maestra SQL Server** (propietaria de Andes Systems) sigue siendo fuente en Fase 1; se escribe contra ella con `sqlx` (`mssql` feature) **solo lectura**, y se materializan vistas en SQLite local.
- **No migrar** `FOXUSER.DBF`, `Thumbs.db`, `.TMP`, `.BAK`, `.ERR`.

### 3.3 Arquitectura Tauri (Rust + React/TypeScript)

```
src-tauri/
  src/
    main.rs / lib.rs
    config/          # cias.json equivalente cifrado (keyring), series, estación
    db/              # pool sqlx, migraciones (0001_init.sql …), ETL hooks
    domain/
      facturacion/   # motor CPE: numeración (correlativos por serie), IGV, perce/retention, detracciones, redondeo
      guia_remision/ # GRE remitente/transportista: motivos TRAS, ubigeo, indicadores SUNAT
      notas/         # NDC/NDD (referencia a F001 origen)
      clientes/      # cnn
      catalogos/     # ta043/077/087/005/086(UNSPSC)/gre61-65 (carga semilla)
      banco/         # che/cheq/cta
      contabilidad/  # pcg/ccf/cdc/asientos/libro ventas
    sunat/
      ubl.rs         # UBL 2.1 builder (Invoice/CreditNote/DebitNote/DespatchAdvice)
      sign.rs        # XMLDSig rsa-sha256 (crate `xml-rs` + `rsa` + `x509-cert`), lee .pfx (PKCS#12, `openssl`/`pkcs12`)
      soap.rs        # sendBill/sendSummary/getStatus (reqwest + quick-xml) — cliente legado SUNAT
      ose_api.rs     # REST proveedor apiandes… (OPCIONAL; preferir directo SUNAT u OSE acreditado)
      cdr.rs         # parseo CDR (zip+xml) → estado
      ticket.rs      # GRETICKET cola + consulta
    xml/pdf/         # Typst templates CPE + `printpdf` para ticket; HTML (handlebars) → PDF (sidecar weasyprint) opción
    email/           # SMTP/STARTTLS (lettre) reemplaza Outlook COM; plantilla Cuprum→HTML inline
    reports/         # render de los 53 formatos (prioridad CPE 6 + gestión diferida)
    ipc/             # #[tauri::command] thin: create_cpe, send_sunat, query_doc, print_preview, export_excel
    security/        # gestión .pfx → keyring/windows-dpapi; secretos fuera del código; rotación JWT/PASS
  migrations/        # SQL del esquema destino + seed catálogos
  assets/            # logos (robinson), recursos
src/                 # React + TS (Vite): vistas CPE, GRE, Clientes, Reportes, Config
```

**Comandos IPC clave:** `emitir_cpe`, `consultar_cpe_sunat`, `generar_gre`, `enviar_gre`, `obtener_cdr`, `previsualizar_pdf`, `exportar_excel`, `listar_documentos`, `sincronizar_sqlserver` (Fase 1), `importar_dbfs` (ETL).

**Mapeo FRX → React:**

| FRX (53) | Destino | Prioridad |
|---|---|---|
| `fac0522/BOL0522/NDC0522/NDD0522.FRX` (representación impresa CPE, con QR/hash) | Typst → PDF (tamaño ticket/A4) | **MVP 1** |
| `gre0522.FRX` (GRE remitente) | Typst → PDF | **MVP 2** |
| `grg0522`/`RCR/CDR/CDB` (resumen boletas / bajas) | Typst/A4 | MVP 2 |
| `REG/RGD/RPC/RCC/RCD/RCE/RDD/RNC/RND/RCS` (gestión) | React table + export `rust_xlsxwriter`/`calamine` | MVP 3 |
| `CHE/CHQ/CHV/CHEDOCPROV` (cheques/vouchers) | Typst + impresora | MVP 3–4 |
| Resto (contabilidad/reportes SUNAT) | diferido | MVP 4+ |

**Impresoras embebidas en FRX** (`DRIVER=winspool DEVICE=HP92F…/Nitro PDF Creator`): eliminar; usar diálogo de impresión/selección en UI.

### 3.4 Plan de migración incremental (MVP por fases)

**Fase 0 — Fundaciones (1–2 sem):** repositorio, esquema SQLite + ETL desde `salida\temp`, semilla catálogos, CI. **Sin tocar operación.**

**Fase 1 — MVP lectura/representación (2–4 sem) — paridad de consulta:**
`documentos (lista/filtro reg)`, `clientes`, `catálogos`, `previsualizar PDF CPE (TYPST)`, `exportar Excel`, `consulta estado SUNAT` (SOAP getStatus). Salida: la operación puede *consultar e imprimir duplicados* sin VFP. Riesgo bajo. **No detiene al sistema actual.**

**Fase 2 — MVP emisión GRE (2–3 sem):** módulo guía rem/trans end-to-end: captura → validaciones SUNAT (ubigeo, motivos) → UBL `DespatchAdvice` → firma → envío (SUNAT directo o proveedor) → ticket + CDR → PDF. Motivo: ya existe contrato API/flujo probado en `SFE0522.PRG`; **es el flujo con menos incógnitas** y el cliente ya emite GRE a diario (166 PDFs).

**Fase 3 — MVP emisión CPE venta (facturas/boletas/NC/ND) (4–6 sem):** motor de documento (IGV/percepción/retención/detracción), UBL Invoice/CreditNote/DebitNote rsa-sha256, envío SOAP SUNAT (o OSE acreditado — recomendado), CDR persistido, representación impresa, envío de correo al cliente (SMTP). **Paridad fiscal aquí.**

**Fase 4 — Cuentas/bancos/contabilidad/libros SUNAT + GRE transportista:** cobranzas, cheques, asientos, libro de ventas (general/simplificado), detracción en BCP.

**Convivencia:** coexistencia con SIADI (lectura sobre SQL Server) hasta paridad completa; escritura nueva solo en destino; corte por módulo con *feature flag*.

### 3.5 Riesgos técnicos específicos encontrados en esta carpeta

1. **Secretos en claro:** `cias.DBF` (`CLAVE_FE`, `CLAVE_DIGI`, `GMAIL_FE/CGMAIL_FE`, `CLAVESQL/USUARIOSQL/IP_SQL`), `estacion.DBF` (`EMAIL_SCHE`), `per.DBF` (`CLAVE` de 6 usuarios), y **JWT Bearer hardcodeado en `SFE0522.PRG` (×6)** con `exp` ≈ 2025-11-29 (expirado). Además **3 `.pfx` con clave privada** en `certificado\20514598224\` sin protección. → Rotar todo; migrar a keyring/DPAPI; nunca en código ni en DBF.
2. **Firma digital legada SHA-1** (`temp.txt`: `SignatureMethod rsa-sha1`, cert vencido 2021-07-21) → SUNAT exige SHA-256 desde 2019/2022; reconstruir firma con rsa-sha256 y cert vigente.
3. **Dependencias 32-bit/OCX:** `iSEDQuickPDF.dll` (QuickPDF ActiveX nativo), `BarCodeLibrary.dll` (COM 32-bit), `foxcrypt.fll` (API VFP), `FRX2Any`+`gdiplus.vcx` (faltante) → no portables a x64/Rust sin reescritura. Reemplazo: `printpdf`/Typst, `zint`/`rxing` para código de barras/PDF417, `RustCrypto` en lugar de FoxCrypt.
4. **Outlook COM / Excel COM** (`envia_email_fe_outlook`, todos los `*_xls`): requiere Outlook/Excel instalado y sesión interactiva → reemplazar por SMTP + generación nativa.
5. **Lógica acoplada a la UI:** patrones VFP (`Click/Valid/InteractiveChange` en `.scx` ausentes aquí) — el código que sí está muestra acceso directo a objetos de form desde librerías (`sfefac1.cmbbase1.displayvalue` dentro de FRX, `saccta.grid2.column7.header1.caption`) → fuerte acoplamiento presentación/datos; al reescribir, separar dominio puro.
6. **Concurrencia VFP:** `RLOCK()/FLOCK()/…` no visibles (están en el `.exe`), pero el patrón `ANULADO/IMPRESO` + tablas compartidas en red implica bloqueo optimista en destino (columnas `version`/`etag`) y cola transaccional para tickets.
7. **Dos fuentes divergentes** `SFE0522` vs `sfe0488` → definir baseline único antes de portar (fusionar `libroventas*`, `grgxls`, `envia_email_gre_outlook` de 04.88).
8. **Sin `.dbc`:** ninguna constraint garantiza integridad — la migración debe **crear** PKs/FKs/CHECKs y validar (registros duplicados `R0013` en `red.DBF`, fechas 1900-01-01 posibles, `HASH2 C(0)` campos longitud cero en `reg/gre/greticket` — truncados por VFP).
9. **Errores ya presentes:** `sfe0522.ERR` (`=>` en lugar de `>=` líneas 368/518 — SQL malformado en `rched_xls`), `FRX2Any.ERR` (gdiplus ausente; PDF devuelve 1 pág error — los 3 PDFs de ~1 KB en `salida\` son evidencia). No confiar en esos caminos.
10. **Salida embebida y rutas hardcodeadas:** `SYS(5)+SYS(2003)+"\…"` (unidad mapeada), impresoras/WSD embebidas en FRX, `crutasit+"\aduanas\fac_ele\"` (carpeta ausente), emails `robinsonme.com.pe` en plantillas — parametrizar todo.
11. **Logos/plantillas de terceros mezclados** (`FERREVILAX.jpg`, `logorobinson*.{jpg,png}`): verificar licencias y limpiar antes de distribuir.
12. **Datos personales/clientes** en `cnn/reg` (RUCs, emails): DPA/privacidad — cifrado en reposo y control de acceso en la app nueva.
13. **`salida\temp` es copia de la BD**: riesgo de fuga al sincronizar con OneDrive; excluir del nuevo repo; tratar como evidencia, no como seed de producción.
14. **Numeración por serie**: `ser.DBF` + `estacion.DBF(SERIE_*)` + correlativos en SQL Server — requiere tabla `series` con bloqueo transaccional en destino (evitar duplicados SUNAT).

---

## Anexo A — Inventario rápido de archivos clave

- Ejecutables: `siadi.exe`, `siadi 21.04.exe`, `siadi1.exe` (VFP9, idénticos ~1.88 MB) · `actexe.exe/1` · `serie.exe` · `VFPsFirmaCPE.exe`, `VFPsPDF417.exe`, `VFPFirmaXML.dll` (.NET) · `vfp9*.dll` · `BarCodeLibrary.dll`, `iSEDQuickPDF.dll`, `XZip.dll` · `foxcrypt.fll` · `jsonfox.app`, `PDFfile.App` · `frx2any.vcx/vct`
- Fuentes legibles: `SFE0522.PRG` (2,819 l.), `formatos\sfe0488.PRG` (2,750 l.)
- Configuración: `cias.DBF`, `estacion.DBF`, `defbase.DBF`, `defrepor.DBF`, `ser.DBF`, `per.DBF` (temp), `FOXUSER.DBF`
- Datos: 146 DBFs en `salida\temp` (~101k reg.) · reportes: 53 FRX/FRT · xlsx/xls plantillas (23) · 166 PDFs emitidos · CDR SUNAT (`response.txt/xml`, `ticket_baja.xml`) · certs 3 PFX
- Ausentes: fuentes del ERP (`.scx/.vcx/.prg`), `.dbc`, `config.fpw`, `.ini`, carpeta `aduanas\fac_ele\` (XML/JSON generados), `DBSFE.zip` (29.5 MB, desapareció)

## Anexo B — Encoding, fechas y valores anómalos

- Encoding CP1252/ANSI; VFP `T` = double días desde 1899-12-30; `cam.DBF` desde 1990; `HASH2 C(0)` (longitud 0 en reg/gre/greticket); `_NullFlags` en 14 tablas.
- `red.DBF` con `N_ORDEN`/`RUC_EMIS` mezclados `20513233605` (Andes Systems, emisor demo) y `20601100984`/`20510069251` (terceros) ⇒ tabla de **retenciones recibidas** multi-proveedor.
- 3 PDFs de ~1 KB = errores de render FRX2Any (gdiplus ausente) — confirma fragilidad del pipeline actual de PDFs.

## Anexo C — Decisiones recomendadas (resumen ejecutivo)

1. **No portar VFP**: reescritura con paridad por módulo; SQL Server como fuente transicional; SQLite embebido destino (o PostgreSQL si se consolida multi-estación).
2. **Primero GRE** (contrato REST ya validado en código), luego CPE venta, luego gestión.
3. **Firma rsa-sha256 + cert vigente** y **rotación inmediata de todos los secretos** (JWT, `CLAVE_FE`, `CLAVESQL`, `CLAVE` usuarios, PFX).
4. **Typst/HTML→PDF** en lugar de FRX2Any+iSEDQuickPDF+GDI+32; **SMTP** en lugar de Outlook COM; **rust_xlsxwriter** en lugar de Excel COM.
5. **Crear integridad en destino** (PK/FK/CHECK + validador en ETL), UTF-8, epoch ISO-8601.
6. Tratar esta carpeta como **solo evidencia/referencia**; nunca como seed de producción (contiene datos personales y secretos).
