# MVP — Sistema de órdenes de análisis de agua

## Propósito

Digitalizar el flujo interno del laboratorio para eliminar la transcripción manual de resultados entre bitácoras, órdenes de análisis e informes. El sistema debe conservar trazabilidad por muestra, parámetro, usuario y fecha, y facilitar el control operativo y las auditorías.

## Alcance del MVP

El MVP cubre desde el registro de una orden hasta la generación de un informe listo para revisión. No sustituye las bitácoras ni los cálculos técnicos de cada método en esta primera fase.

### Flujo objetivo

1. Recepción registra una **orden de análisis** (OP) y sus muestras.
2. Selecciona una norma o paquete de análisis; el sistema agrega automáticamente sus parámetros. También puede crear un análisis personalizado.
3. Los analistas capturan el resultado de los parámetros que les correspondan.
4. El sistema marca el avance de cada muestra y de la orden: pendiente, en proceso o completa.
5. Cuando todos los resultados requeridos están completos, recepción revisa y genera el informe con los datos ya consolidados.
6. El informe se descarga como PDF y queda registrado como emitido.

## Personas y permisos

| Rol | Puede hacer |
| --- | --- |
| Administrador | Gestionar usuarios, clientes, parámetros, normas/paquetes y plantillas. Ver y corregir cualquier orden con trazabilidad. |
| Recepción / informes | Crear OP y muestras, asignar paquetes, consultar el avance, revisar datos, generar y emitir informes. No modifica resultados validados. |
| Analista | Ver únicamente las órdenes y parámetros asignados. Capturar, corregir y enviar sus resultados para revisión. |
| Revisor técnico (opcional en MVP) | Aprobar o devolver resultados e informes antes de emitirlos. |

Todo acceso requiere cuenta individual con correo y contraseña. Nunca se comparten usuarios. El sistema guarda quién creó, editó, validó o emitió cada registro y cuándo.

## Requisitos funcionales

### Regla confirmada de OP, muestra e informe

- En la primera versión, cada registro de recepción corresponde a **una OP, una muestra, un número de muestreo y un informe**.
- El número de OP se genera automáticamente al registrar la recepción, con el formato `2YYMMCCC`:
  - `2YY`: año con el prefijo `2` (2025 → `225`; 2026 → `226`).
  - `MM`: mes de la fecha de recepción (`01` a `12`).
  - `CCC`: consecutivo anual de tres dígitos, que continúa durante todo el año y no se reinicia cada mes.
  - Ejemplos: primera recepción de enero de 2026 → `22601001`; recepción número 359 del año, en agosto de 2026 → `22608359`.
- El **número de muestreo** y el **número de muestra** son campos distintos, ambos de captura manual y obligatorios:
  - El número de muestreo lo asigna el programador de muestreos.
  - El número de muestra es el identificador interno único que utiliza el personal analítico para identificar la muestra.
  - Ambos campos deben mostrarse en la tabla de entrada de muestras y en la orden de análisis vinculada.
- La fecha de muestreo se captura manualmente.
- La fecha de compromiso se calcula automáticamente: ocho días hábiles, comenzando a contar el día hábil posterior a la fecha de recepción. En la primera versión, “hábil” excluye sábados y domingos; los días festivos se incorporarán cuando se defina un calendario operativo.
- El número de informe inicia vacío y se asigna únicamente cuando la encargada emite el informe final.

### 1. Catálogos administrables

- Clientes: nombre, identificador interno, datos de contacto y estatus.
- Parámetros: nombre, unidad, método/norma mexicana aplicable, precisión decimal de reporte, tipo de resultado (numérico, texto, menor que), analista responsable y activo/inactivo.
- Normas o paquetes: nombre/código y lista de parámetros requeridos. Ejemplos: NOM-001, NOM-002, NOM-003 y personalizado.
- Plantillas de informe: formato por norma/paquete, incluyendo campos y tabla de resultados.
- Usuarios y roles.

### 2. Registrar una OP

- Generar o registrar un número OP único.
- Capturar: cliente, número de muestreo, muestreador, fecha/hora de entrada, fecha comprometida, norma o tipo de análisis y notas.
- Una OP puede tener una o varias muestras; cada muestra tiene un ID único y, cuando aplique, punto de muestreo/descripción.
- Seleccionar un paquete agrega sus parámetros a cada muestra; un análisis personalizado permite agregar y quitar parámetros manualmente.
- Mostrar el conteo de parámetros solicitados por orden y por muestra.

### 3. Lista de trabajo y control de estado

- Listado de OP con búsqueda por OP, cliente, informe, muestra, fecha y estado.
- Estados mínimos: `registrada`, `en proceso`, `completa`, `en revisión`, `informe emitido`, `cancelada`.
- Indicador rojo para órdenes incompletas y verde para órdenes completas; mostrar también el porcentaje de parámetros terminados.
- Alertar/filtrar órdenes cercanas o vencidas respecto a la fecha comprometida (el KPI actual usa 18 días desde la entrada, configurable).
- Una OP precapturada no se considera emitida ni entra como informe terminado hasta que se complete la información requerida.

### 4. Captura de resultados

- Para cada parámetro de una muestra: resultado, unidad, fecha/hora de captura, observación y analista.
- Admitir valores numéricos y resultados cualitativos como `menor que X`.
- Cada parámetro define su precisión decimal de reporte conforme a su método/norma mexicana. La interfaz limita o redondea el valor a esa precisión al guardar y mostrar el resultado.
- Por ahora no se validan rangos de aceptación, fórmulas ni límites de cumplimiento; el sistema registra el resultado reportado por el analista.
- Un analista sólo puede editar resultados de sus parámetros asignados.
- El sistema actualiza automáticamente el avance de muestra y OP cuando se guarda un resultado.
- No permitir marcar una orden completa si faltan parámetros requeridos.
- Las correcciones conservan el valor anterior, el nuevo, usuario, fecha y justificación; no se sobrescriben silenciosamente.

### 5. Revisión e informe

- Recepción puede abrir la orden completa y revisar la tabla consolidada por muestra y parámetro.
- Sólo se habilita “Generar informe” cuando la orden esté completa (o con una excepción registrada por un revisor).
- Generar un PDF desde una plantilla con cliente, OP, número de informe, muestras, puntos de muestreo, resultados, unidades, fechas y firma/leyenda aplicable.
- Guardar número de informe único, fecha de emisión, versión del PDF y enlace al archivo.
- El informe emitido queda bloqueado; una corrección posterior crea una nueva versión, nunca reemplaza la evidencia anterior.

### 6. Reportes operativos y auditoría

- Conteo de análisis solicitados por parámetro, norma/paquete y rango de fechas. Este es el reporte prioritario para auditorías.
- Conteo de OP, muestras e informes emitidos por periodo.
- KPI de tiempo de entrega: días entre entrada y emisión, cumplimiento frente al límite configurable.
- Exportación CSV/Excel de listados y reportes.
- Historial auditable de eventos relevantes: creación, cambios, captura, revisión, emisión y cancelación.

## Modelo de datos inicial

```text
Usuario ──< EventoAuditoria
Cliente ──< OrdenAnalisis (OP) ──< Muestra ──< Resultado >── Parametro
                                  └──< Resultado
Paquete/Norma ──< PaqueteParametro >── Parametro
OrdenAnalisis ──< Informe
Usuario ──< Resultado (analista responsable/capturó)
```

Entidades clave: `usuarios`, `roles`, `clientes`, `ordenes_analisis`, `muestras`, `parametros`, `paquetes`, `paquete_parametros`, `resultados`, `informes` y `eventos_auditoria`.

## Requisitos no funcionales

- Interfaz web responsive para computadora; optimizada primero para el uso en laboratorio.
- Idioma inicial: español; fechas en formato mexicano y zona horaria `America/Mexico_City`.
- Autorización aplicada en base de datos, no sólo ocultando botones en pantalla.
- HTTPS, contraseñas gestionadas por un proveedor de autenticación y copias de seguridad.
- Validaciones de tipos, unidades y campos obligatorios; evitar resultados duplicados para la misma muestra/parámetro.
- Debe preservar evidencia: no eliminar físicamente resultados o informes emitidos desde la interfaz normal.

## Fuera del MVP

- Digitalizar o recalcular las bitácoras y hojas de cálculo de cada método.
- Importar OP históricas: el sistema inicia con órdenes nuevas; los registros ya existentes permanecen en los archivos actuales.
- Instrumentación de laboratorio e integración directa con equipos.
- Portal para clientes, facturación, cotizaciones y pagos.
- Aplicación móvil nativa.
- Sustitución completa del sistema de calidad/documentación física.

## Decisiones de arquitectura recomendadas

- **Frontend:** aplicación web con React/Next.js.
- **Base de datos + autenticación:** Supabase (PostgreSQL, Auth y almacenamiento de PDFs). Es preferible a una base documental para este caso porque OP, muestras, parámetros y resultados son relaciones claras y requieren reportes con filtros/agrupaciones.
- **Backend:** sí se necesita lógica del lado servidor para permisos, generación de PDF, numeración segura de informes y auditoría. Puede implementarse con rutas del propio framework y/o funciones de Supabase; no requiere administrar un servidor tradicional al inicio.
- **Seguridad:** Row Level Security (RLS) para limitar por rol los registros que cada usuario puede leer o editar.

Supabase ofrece actualmente dos proyectos gratis, PostgreSQL con hasta 500 MB por proyecto, 1 GB de almacenamiento, y hasta 50,000 usuarios activos mensuales en su plan gratuito. Es suficiente para un piloto interno; los PDFs y adjuntos son lo que probablemente exigirán vigilar primero. [Documentación oficial de límites y facturación](https://supabase.com/docs/guides/platform/billing-on-supabase).

## Criterios de éxito del MVP

- Crear una OP con varias muestras y un paquete completo sin capturar parámetros uno por uno.
- Cada analista captura resultados sin poder alterar los de otros analistas.
- La orden cambia a completa automáticamente al registrar todos los resultados requeridos.
- Se genera un informe PDF con los resultados correctos sin reescribirlos en Word.
- En una auditoría se puede obtener, por periodo, el total de análisis realizados para cualquier parámetro.
- Toda modificación relevante puede atribuirse a una cuenta y fecha.

## Preguntas para cerrar antes de construir

1. ¿Cuál es la lista definitiva de parámetros, paquetes/normas, unidades y métodos?
2. ¿Qué campos exactos y diseño debe llevar el informe PDF actual?
3. ¿Quién puede validar técnicamente resultados y firmar/autorizar un informe?
4. Confirmado: no se importarán OP históricas; el sistema iniciará con órdenes nuevas.
5. Confirmado parcialmente: no habrá validación de rangos, fórmulas ni límites por ahora. Falta definir, para cada parámetro, la precisión decimal indicada por su método/norma mexicana.
