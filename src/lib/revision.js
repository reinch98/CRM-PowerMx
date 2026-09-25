// ---------------------------------------------------------------------------
// El formato de mantenimiento, resumido para el celular (SQL 24).
//
// El formato solar en papel (PMX-FR-MTTO-01 Rev. 2.0) trae ~55 puntos repartidos en cuatro
// hojas. Aquí van 32: se fusionaron los puntos que el técnico revisa de una sola pasada
// (limpieza + vidrio + marco es "estado del módulo"), pero **la sección de seguridad no se
// recortó**: es la que protege legalmente y es la que bloquea el cierre.
//
// Este archivo es el CATÁLOGO (qué se pregunta y en qué orden). Las respuestas viven en
// `orden_revision.datos`. Se separa así porque el catálogo cambia cuando cambia el formato
// en papel, y lo comparten la pantalla del técnico y el PDF de la orden.
//
// Cada punto se califica B / R / M / N/A. La caja de hallazgo y los campos numéricos solo
// se muestran cuando hacen falta: en el papel son 40 renglones en blanco, aquí sale el que
// importa.
// ---------------------------------------------------------------------------

export const CALIFICACIONES = [
  ['B', 'Bueno'],
  ['R', 'Regular'],
  ['M', 'Malo'],
  ['NA', 'No aplica'],
]

// Secciones 1 a 5 del formato resumido. Las 6 a 9 (mediciones, placas, evidencia y cierre)
// no son listas de puntos y las arma la pantalla.
export const FORMATO_SOLAR = [
  {
    clave: '1',
    titulo: 'Seguridad',
    ayuda: 'Antes de tocar el sistema. Si algo queda en "Malo", escribe qué hiciste para compensarlo o el servicio se suspende.',
    bloquea: true,
    puntos: [
      { clave: '1.1', titulo: 'Análisis de seguridad (AST/APR)', detalle: 'Elaborado, comunicado y firmado por toda la cuadrilla.' },
      { clave: '1.2', titulo: 'Permisos de trabajo vigentes', detalle: 'Trabajo eléctrico y trabajo en alturas, si aplica.' },
      { clave: '1.3', titulo: 'LOTO: bloqueo y etiquetado', detalle: 'Aislamiento de fuentes DC (arreglo FV y banco) y AC (red y cargas).' },
      { clave: '1.4', titulo: 'Ausencia de tensión comprobada', detalle: 'Las cinco reglas de oro.', campos: [['v_residual', 'Tensión residual (V)']] },
      { clave: '1.5', titulo: 'EPP completo', detalle: 'Casco, gafas, guantes y calzado dieléctricos, arnés si aplica.' },
      { clave: '1.6', titulo: 'Área delimitada y extintor', detalle: 'Señalizada, con extintor CO2/ABC accesible y con carga vigente.' },
      { clave: '1.7', titulo: 'Instrumentos calibrados', detalle: 'Multímetro, pinza, megóhmetro y cámara IR con certificado vigente.', campos: [['cert', 'Certificado núm.']] },
      { clave: '1.8', titulo: 'Clima seguro para cubierta', detalle: 'Sin lluvia y viento por debajo de 30 km/h.' },
    ],
  },
  {
    clave: '2',
    titulo: 'Módulos y estructura',
    puntos: [
      { clave: '2.1', titulo: 'Estado del módulo', detalle: 'Limpieza, vidrio y celdas (microfisuras, delaminación, browning, snail trails), marco y backsheet.', campos: [['soiling', 'Suciedad estimada (%)']] },
      { clave: '2.2', titulo: 'Termografía infrarroja', detalle: 'Bajo carga, arriba de 600 W/m². Puntos calientes y diodos de paso averiados.', campos: [['dt', 'ΔT máx (°C)'], ['afectados', 'Módulos afectados']], necesita: 'irradiancia' },
      { clave: '2.3', titulo: 'Estructura y anclajes', detalle: 'Firmes, sin oxidación ni corrosión galvánica; torque verificado en grapas.', campos: [['torque', 'Torque (N·m)']] },
      { clave: '2.4', titulo: 'Conectores MC4 y cableado', detalle: 'Herméticos, sin recalentamiento; sujetos y protegidos de UV y roce.' },
      { clave: '2.5', titulo: 'Tierra de marcos y rieles', detalle: 'Continuidad módulo – estructura – conductor de cobre desnudo.', campos: [['continuidad', 'Continuidad (Ω)']] },
      { clave: '2.6', titulo: 'Entorno y cubierta', detalle: 'Sombreados nuevos, sellos e impermeabilización, canalizaciones y charolas.' },
    ],
  },
  {
    clave: '3',
    titulo: 'Inversores y controladores',
    puntos: [
      { clave: '3.1', titulo: 'Ventilación y gabinete', detalle: 'Disipador, rejillas y filtros limpios; ventiladores girando. Sellado IP/NEMA sin fauna ni humedad.' },
      { clave: '3.2', titulo: 'Terminales de potencia DC/AC', detalle: 'Torque en bornes; sin decoloración por temperatura.', campos: [['torque', 'Torque (N·m)']] },
      { clave: '3.3', titulo: 'Historial de alarmas', detalle: 'Descarga y análisis del log: aislamiento, sobrevoltajes, red fuera de rango.', campos: [['codigos', 'Código(s)']] },
      { clave: '3.4', titulo: 'Firmware y comunicación', detalle: 'Versión, conectividad Wi-Fi / Ethernet / RS485 y enlace al portal.', campos: [['fw', 'Versión de firmware']] },
      { clave: '3.5', titulo: 'Pruebas de operación', detalle: 'Seccionamiento DC, desconexión anti-isla, paro y rearranque completos.', campos: [['t_reconexion', 'Tiempo de reconexión (s)']] },
      { clave: '3.6', titulo: 'Monitoreo y parámetros de red', detalle: 'Lo reportado en plataforma contra la medición en campo; ventanas de tensión y frecuencia.', campos: [['desviacion', 'Desviación (%)']] },
    ],
  },
  {
    clave: '4',
    titulo: 'Banco de baterías (BESS)',
    ayuda: 'Solo si el sistema tiene almacenamiento.',
    solo: 'bess',
    puntos: [
      { clave: '4.1', titulo: 'Estado físico de gabinetes y racks', detalle: 'Sin hinchamiento, fugas de electrolito, grietas ni deformaciones.' },
      { clave: '4.2', titulo: 'Bornes y terminales', detalle: 'Limpieza de sulfatación, grasa dieléctrica y reapriete con torquímetro.', campos: [['torque', 'Torque (N·m)']] },
      { clave: '4.3', titulo: 'Diagnóstico del BMS', detalle: 'Comunicación CAN/RS485 estable, sin alarmas activas.', campos: [['soc', 'SOC (%)'], ['soh', 'SOH (%)']] },
      { clave: '4.4', titulo: 'Balance de celdas', detalle: 'Desviación de voltaje entre celdas dentro de especificación.', campos: [['dv', 'ΔV máx (mV)']] },
      { clave: '4.5', titulo: 'Ciclado y profundidad de descarga', detalle: 'Ciclos acumulados y DoD conforme al diseño.', campos: [['ciclos', 'Ciclos'], ['dod', 'DoD (%)']] },
      { clave: '4.6', titulo: 'Sala: clima, sensores y contra incendio', detalle: 'Temperatura 18–25 °C, extracción de gases, sensores de humo y supresión vigentes.', campos: [['temp_sala', 'Temp. de sala (°C)']] },
      { clave: '4.7', titulo: 'Protecciones y pruebas de respaldo', detalle: 'Fusibles y seccionadores de rack; simulación de falla de red y prueba de carga/descarga.', campos: [['t_conmutacion', 'Conmutación (ms)'], ['i_max', 'I máx (A)'], ['t_max', 'T máx (°C)']] },
      { clave: '4.8', titulo: 'Electrolito y densidad', detalle: 'Nivel de agua destilada sobre placas y densidad por celda.', campos: [['densidad', 'Densidad prom. (g/cm³)']], solo: 'plomo' },
    ],
  },
  {
    clave: '5',
    titulo: 'Tableros, protecciones y tierra',
    puntos: [
      { clave: '5.1', titulo: 'Supresores de sobretensión (SPD)', detalle: 'Banderas e indicadores: verde operativo, rojo sustituir. DC y AC.' },
      { clave: '5.2', titulo: 'Fusibles e interruptores', detalle: 'Fusibles gPV, operatividad mecánica y disparo de termomagnéticos.' },
      { clave: '5.3', titulo: 'Torque en barras y peines', detalle: 'Reapriete en tablero de combinación y tablero de respaldo.' },
      { clave: '5.4', titulo: 'Termografía de tableros', detalle: 'Bajo carga, sin puntos calientes en barras, zapatas ni protecciones.', campos: [['dt', 'ΔT máx (°C)']] },
      { clave: '5.5', titulo: 'Tierra, paro de emergencia y documentación', detalle: 'Prueba de GFDI/RCD y botón de paro; registro y soldaduras del electrodo; etiquetado y unifilar al día.' },
    ],
  },
]

// ---------------------------------------------------------------------------
// Generador (PMX-SRV, "Formato de Revisión y Servicio a Generadores", 9 páginas).
//
// Los sistemas 3.1 a 3.8 del papel, con los puntos de COMBUSTIBLE desglosados: un diésel,
// una planta de gasolina y una de gas LP no se revisan igual, y el papel los tenía juntos
// en una sola lista que el técnico iba salteando.
//   · diésel   → trampa de agua, dos filtros, edad del combustible, purga de aire
//   · gasolina → filtro único, barniz en carburador, válvula de paso, bujías
//   · gas      → regulador y presión, fuga con jabón, solenoide, mangueras, bujías
// El gas natural lleva lo mismo que el LP salvo el vaporizador, que es de LP.
//
// La sección 1 (seguridad) NO viene en el formato en papel: se agregó porque es la que
// bloquea el cierre, y porque antes de arrancar una planta de gas hay que descartar fuga.
// ---------------------------------------------------------------------------
export const COMBUSTIBLES_GEN = [
  ['diesel', 'Diésel'],
  ['gasolina', 'Gasolina'],
  ['gas_lp', 'Gas LP'],
  ['gas_natural', 'Gas natural'],
]

const CHISPA = ['gasolina', 'gas_lp', 'gas_natural']
const GAS = ['gas_lp', 'gas_natural']

export const FORMATO_GENERADOR = [
  {
    clave: '1',
    titulo: 'Seguridad',
    ayuda: 'Antes de abrir o arrancar. Si algo queda en "Malo", escribe qué hiciste para compensarlo o el servicio se suspende.',
    bloquea: true,
    puntos: [
      { clave: '1.1', titulo: 'Bloqueo del arranque automático', detalle: 'El equipo no puede arrancar solo mientras tienes las manos dentro.' },
      { clave: '1.2', titulo: 'Sin fuga de gas antes de arrancar', detalle: 'Uniones y conexiones probadas con solución jabonosa; área ventilada y sin fuentes de ignición.', solo: GAS },
      { clave: '1.3', titulo: 'Área ventilada y escape libre', detalle: 'Sin acumulación de gases; la salida de escape no da a tomas de aire ni a zonas de paso.' },
      { clave: '1.4', titulo: 'EPP y superficies calientes', detalle: 'Guantes, gafas y protección auditiva; escape y radiador señalizados.' },
      { clave: '1.5', titulo: 'Extintor accesible y vigente', detalle: 'Con carga vigente y a la mano.' },
    ],
  },
  {
    clave: '2',
    titulo: 'Motor y lubricación',
    puntos: [
      { clave: '2.1', titulo: 'Nivel y condición del aceite', detalle: 'Color, olor a combustible y presencia de agua.' },
      { clave: '2.2', titulo: 'Fugas de aceite', detalle: 'Cárter, retenes, filtro y tapa de punterías.' },
      { clave: '2.3', titulo: 'Filtro de aceite', detalle: 'Estado o cambio realizado.', campos: [['cambio', 'Fecha del cambio']] },
      { clave: '2.4', titulo: 'Bandas', detalle: 'Tensión, grietas y alineación.' },
      { clave: '2.5', titulo: 'Soportes antivibratorios y tornillería' },
      { clave: '2.6', titulo: 'Ruidos o vibración anormal' },
      { clave: '2.7', titulo: 'Calentador de camisas (block heater)', detalle: 'Que caliente: un motor frío arranca tarde y se desgasta más.' },
    ],
  },
  {
    clave: '3',
    titulo: 'Combustible',
    puntos: [
      { clave: '3.1', titulo: 'Nivel del tanque', campos: [['nivel', 'Nivel (%)']] },
      { clave: '3.2', titulo: 'Mangueras, abrazaderas y fugas' },
      { clave: '3.3', titulo: 'Bomba de transferencia o flotador', solo: ['diesel', 'gasolina'] },

      { clave: '3.4', titulo: 'Trampa de agua drenada', detalle: 'Agua y sedimento en el fondo del tanque y en el separador.', solo: ['diesel'] },
      { clave: '3.5', titulo: 'Filtros primario y secundario', detalle: 'Los dos filtros del diésel.', campos: [['cambio', 'Fecha del cambio']], solo: ['diesel'] },
      { clave: '3.6', titulo: 'Edad del combustible', detalle: 'Diésel con más de 6 meses: tomar muestra. Se degrada y cría hongo.', campos: [['meses', 'Meses en el tanque']], solo: ['diesel'] },
      { clave: '3.7', titulo: 'Purga de aire del sistema', detalle: 'Después de cambiar filtros; sin purgar, el motor no toma carga.', solo: ['diesel'] },

      { clave: '3.8', titulo: 'Filtro de gasolina', campos: [['cambio', 'Fecha del cambio']], solo: ['gasolina'] },
      { clave: '3.9', titulo: 'Combustible viejo o con barniz', detalle: 'La gasolina se descompone en meses y tapa el carburador. Revisa si lleva estabilizador.', solo: ['gasolina'] },
      { clave: '3.10', titulo: 'Válvula de paso y líneas', detalle: 'Cierra bien y no gotea.', solo: ['gasolina'] },

      { clave: '3.11', titulo: 'Regulador y presión de entrada', detalle: 'Presión dentro de lo que pide el fabricante.', campos: [['presion', 'Presión (columna de agua)']], solo: GAS },
      { clave: '3.12', titulo: 'Prueba de fugas con solución jabonosa', detalle: 'Todas las uniones, con el sistema presurizado.', solo: GAS },
      { clave: '3.13', titulo: 'Válvula de corte manual y solenoide', detalle: 'Corta de verdad al quitar la señal.', solo: GAS },
      { clave: '3.14', titulo: 'Mangueras flexibles vigentes', detalle: 'Sin fisuras ni resecamiento, dentro de su vida útil.', solo: GAS },
      { clave: '3.15', titulo: 'Toma de vapor y vaporizador', detalle: 'Si el tanque entrega líquido, el vaporizador tiene que estar trabajando.', solo: ['gas_lp'] },
      { clave: '3.16', titulo: 'Detector de gas del cuarto', detalle: 'El LP es más pesado que el aire y se acumula abajo; el natural, al revés. El detector va donde corresponde.', solo: GAS },
    ],
  },
  {
    clave: '4',
    titulo: 'Encendido',
    ayuda: 'Solo en motores de chispa. Un diésel no lleva bujías.',
    solo: CHISPA,
    puntos: [
      { clave: '4.1', titulo: 'Bujías: estado y separación', campos: [['separacion', 'Separación (mm)']], solo: CHISPA },
      { clave: '4.2', titulo: 'Cables de encendido y bobinas', solo: CHISPA },
    ],
  },
  {
    clave: '5',
    titulo: 'Enfriamiento',
    puntos: [
      { clave: '5.1', titulo: 'Nivel y concentración del refrigerante', campos: [['ph', 'pH o punto de ebullición']] },
      { clave: '5.2', titulo: 'Radiador', detalle: 'Panal limpio, sin obstrucción ni corrosión.' },
      { clave: '5.3', titulo: 'Mangueras y abrazaderas' },
      { clave: '5.4', titulo: 'Ventilador y guarda' },
      { clave: '5.5', titulo: 'Tapón del radiador', detalle: 'Sella y mantiene presión.' },
    ],
  },
  {
    clave: '6',
    titulo: 'Admisión y escape',
    puntos: [
      { clave: '6.1', titulo: 'Filtro de aire e indicador de restricción', campos: [['cambio', 'Fecha del cambio']] },
      { clave: '6.2', titulo: 'Ductos de admisión y abrazaderas' },
      { clave: '6.3', titulo: 'Silenciador, juntas y fugas de escape' },
      { clave: '6.4', titulo: 'Salida de escape libre', detalle: 'Lejos de tomas de aire, ventanas y zonas de paso.' },
      { clave: '6.5', titulo: 'Color del humo', detalle: 'En arranque y con carga. Negro: exceso de combustible o falta de aire. Azul: aceite. Blanco: agua o mala combustión.' },
    ],
  },
  {
    clave: '7',
    titulo: 'Batería y arranque',
    puntos: [
      { clave: '7.1', titulo: 'Voltaje en reposo', campos: [['v_reposo', 'Voltaje (V)']] },
      { clave: '7.2', titulo: 'Voltaje durante el arranque', detalle: 'Si se desploma, la batería ya no da.', campos: [['v_arranque', 'Voltaje (V)']] },
      { clave: '7.3', titulo: 'Bornes', detalle: 'Sulfatación, apriete y grasa dieléctrica.' },
      { clave: '7.4', titulo: 'Electrolito y edad de la batería', campos: [['fabricacion', 'Fecha de fabricación']] },
      { clave: '7.5', titulo: 'Cargador de batería', campos: [['v_carga', 'V de carga'], ['a_carga', 'A de carga']] },
      { clave: '7.6', titulo: 'Motor de arranque y alternador de carga' },
    ],
  },
  {
    clave: '8',
    titulo: 'Alternador y parte eléctrica',
    puntos: [
      { clave: '8.1', titulo: 'Limpieza y ventilación del alternador' },
      { clave: '8.2', titulo: 'Conexiones de potencia', detalle: 'Apriete y señales de calentamiento.' },
      { clave: '8.3', titulo: 'Interruptor principal (breaker)' },
      { clave: '8.4', titulo: 'Aislamiento de devanados (megóhmetro)', detalle: 'Va en el servicio mayor.', campos: [['megohm', 'Aislamiento (MΩ)']], solo: 'mayor' },
      { clave: '8.5', titulo: 'Puesta a tierra del equipo y neutro' },
      { clave: '8.6', titulo: 'Regulador de voltaje (AVR)' },
    ],
  },
  {
    clave: '9',
    titulo: 'Tablero y transferencia',
    puntos: [
      { clave: '9.1', titulo: 'Alarmas activas e historial', campos: [['codigos', 'Código(s)']] },
      { clave: '9.2', titulo: 'Paro de emergencia funcional' },
      { clave: '9.3', titulo: 'Protecciones', detalle: 'Baja presión de aceite, alta temperatura y sobrevelocidad.' },
      { clave: '9.4', titulo: 'Modo automático habilitado al terminar', detalle: 'Si se queda en manual, la planta no arranca cuando se va la luz.' },
      { clave: '9.5', titulo: 'ATS: contactos, mecanismo y tiempos' },
      { clave: '9.6', titulo: 'Ejercitador semanal programado' },
    ],
  },
  {
    clave: '10',
    titulo: 'Gabinete y entorno',
    puntos: [
      { clave: '10.1', titulo: 'Corrosión', detalle: 'Crítico a menos de 5 km del mar: gabinete, tornillería y terminales.' },
      { clave: '10.2', titulo: 'Sellos, puertas y cerraduras' },
      { clave: '10.3', titulo: 'Ventilación del cuarto o caseta' },
      { clave: '10.4', titulo: 'Fauna, nidos o basura dentro del equipo' },
      { clave: '10.5', titulo: 'Drenaje, base y anclaje' },
    ],
  },
]

// Tipos de servicio del formato de generadores (el anexo de periodicidad).
export const TIPOS_SERVICIO_GEN = [
  ['A', 'Tipo A · Inspección', 'Mensual. Revisión visual, batería y prueba en vacío de 15 a 30 min.'],
  ['B', 'Tipo B · Preventivo', '250 h o 6 meses. Todo A más aceite, filtros de aceite y combustible, y prueba con carga.'],
  ['C', 'Tipo C · Mayor', '500 h o 12 meses. Todo B más filtro de aire, refrigerante, bandas, megóhmetro y prueba de ATS.'],
]

// ---------------------------------------------------------------------------
// Mediciones
//
// En el papel son tablas anchas con columnas fijas: seis strings aunque la instalación
// tenga dos, y tres fases aunque el equipo sea monofásico. Aquí los strings se agregan uno
// a uno y las fases que no existen no se preguntan.
// ---------------------------------------------------------------------------

// Generador: cada lectura se toma EN VACÍO y CON CARGA (sección 4 del formato).
export const LECTURAS_GEN = [
  { clave: 'v_l1l2', titulo: 'Voltaje L1-L2', unidad: 'V', solo: 'trifasico' },
  { clave: 'v_l2l3', titulo: 'Voltaje L2-L3', unidad: 'V', solo: 'trifasico' },
  { clave: 'v_l3l1', titulo: 'Voltaje L3-L1', unidad: 'V', solo: 'trifasico' },
  { clave: 'v_ln', titulo: 'Voltaje L-N', unidad: 'V' },
  { clave: 'i_l1', titulo: 'Corriente L1', unidad: 'A' },
  { clave: 'i_l2', titulo: 'Corriente L2', unidad: 'A', solo: 'trifasico' },
  { clave: 'i_l3', titulo: 'Corriente L3', unidad: 'A', solo: 'trifasico' },
  { clave: 'frecuencia', titulo: 'Frecuencia', unidad: 'Hz', espera: '60 ± 0.5' },
  { clave: 'p_activa', titulo: 'Potencia activa', unidad: 'kW' },
  { clave: 'fp', titulo: 'Factor de potencia', unidad: '' },
  { clave: 'p_aceite', titulo: 'Presión de aceite', unidad: 'psi' },
  { clave: 't_refrigerante', titulo: 'Temperatura de refrigerante', unidad: '°C' },
  { clave: 'rpm', titulo: 'RPM', unidad: 'rpm', espera: '1800 o 3600' },
  { clave: 'v_bateria', titulo: 'Voltaje de batería en marcha', unidad: 'V' },
]

export const TIPOS_TRANSFERENCIA = [
  ['simulacion', 'Simulación de falla de red'],
  ['carga_real', 'Carga real'],
  ['banco', 'Banco de carga'],
]

export const TRANSFERENCIA_GEN = [
  ['t_arranque', 'Arranque hasta tomar carga (s)'],
  ['t_retransferencia', 'Retransferencia a la red (s)'],
  ['t_enfriamiento', 'Enfriamiento programado (min)'],
]

// Solar: parámetros AC en el tablero y lecturas del banco y la tierra.
export const AC_SOLAR = [
  { clave: 'l1n', titulo: 'L1-N', unidad: 'V' },
  { clave: 'l2n', titulo: 'L2-N', unidad: 'V', solo: 'trifasico' },
  { clave: 'l3n', titulo: 'L3-N', unidad: 'V', solo: 'trifasico' },
  { clave: 'l1l2', titulo: 'L1-L2', unidad: 'V', solo: 'trifasico' },
  { clave: 'l2l3', titulo: 'L2-L3', unidad: 'V', solo: 'trifasico' },
  { clave: 'l3l1', titulo: 'L3-L1', unidad: 'V', solo: 'trifasico' },
  { clave: 'frecuencia', titulo: 'Frecuencia', unidad: 'Hz', espera: '60 ± 0.5' },
]

export const BANCO_SOLAR = [
  { clave: 'v_banco', titulo: 'Voltaje del banco', unidad: 'Vdc', solo: 'bess' },
  { clave: 'i_carga', titulo: 'Corriente de carga', unidad: 'A', solo: 'bess' },
  { clave: 'i_descarga', titulo: 'Corriente de descarga', unidad: 'A', solo: 'bess' },
  { clave: 't_celda', titulo: 'Temperatura máxima de celda', unidad: '°C', solo: 'bess' },
  { clave: 'r_tierra', titulo: 'Resistencia de tierra', unidad: 'Ω', espera: 'menos de 10' },
  { clave: 'produccion', titulo: 'Producción del día', unidad: 'kWh' },
  { clave: 'pr', titulo: 'Rendimiento (PR)', unidad: '%' },
]

export const COLUMNAS_STRING = [
  ['mppt', 'MPPT'],
  ['voc_teorico', 'Voc teórico (V)'],
  ['voc_medido', 'Voc medido (V)'],
  ['isc', 'Isc / Imp (A)'],
  ['aisl_pos', 'Aislamiento +/tierra (MΩ)'],
  ['aisl_neg', 'Aislamiento −/tierra (MΩ)'],
]

export const VEREDICTOS = {
  pasa: 'Pasa',
  revisar: 'Revisar',
  no_pasa: 'No pasa',
}

export const stringNuevo = () => ({ mppt: '', voc_teorico: '', voc_medido: '', isc: '', aisl_pos: '', aisl_neg: '' })

const numero = v => (v === '' || v === null || v === undefined ? null : Number(v))

// Lo que la medición dice que está mal. No bloquea nada: avisa mientras el técnico sigue
// en el sitio, que es cuando se puede corregir.
export function avisosMediciones(datos, ctx = {}) {
  const avisos = []
  const med = datos?.mediciones || {}

  const hz = [numero(med.ac?.frecuencia), numero(med.lecturas?.frecuencia?.vacio), numero(med.lecturas?.frecuencia?.carga)]
  if (hz.some(v => v !== null && Number.isFinite(v) && (v < 59.5 || v > 60.5))) {
    avisos.push('La frecuencia se sale de 60 ± 0.5 Hz.')
  }

  const tierra = numero(med.banco?.r_tierra)
  if (tierra !== null && Number.isFinite(tierra) && tierra > 10) {
    avisos.push(`La resistencia de tierra es de ${tierra} Ω: la norma pide menos de 10.`)
  }

  // Wet stacking: un diésel que solo trabaja en vacío o con poca carga acumula hollín.
  const carga = numero(med.carga_pct)
  if (ctx.combustible === 'diesel' && carga !== null && Number.isFinite(carga) && carga < 30) {
    avisos.push(`La prueba con carga fue al ${carga} %. En diésel se pide 30 % o más durante 30 min para que no acumule hollín.`)
  }

  const malos = (med.strings || []).filter(s => veredictoString(s) === 'no_pasa').length
  if (malos > 0) avisos.push(`${malos} string${malos === 1 ? '' : 's'} no pasa${malos === 1 ? '' : 'n'} la prueba de aislamiento.`)

  return avisos
}

// Las placas que se fotografían una vez y quedan en el equipo, no en la orden.
export const PLACAS = [
  ['inversor', 'Inversor'],
  ['modulos', 'Paneles'],
  ['bateria', 'Batería / BESS', 'bess'],
  ['bms', 'BMS / monitoreo'],
]

export const DICTAMENES = [
  ['aprobado', 'Aprobado', 'Operación óptima y segura. Queda en servicio sin restricciones.'],
  ['condicionado', 'Condicionado', 'Requiere correcciones menores programadas. Opera bajo seguimiento.'],
  ['no_aprobado', 'No aprobado', 'Riesgo inminente o fuera de servicio. Se aísla el sistema y se avisa de inmediato.'],
]

// ---- reglas puras ----

const puntosDe = seccion => seccion.puntos || []

// Cuándo se muestra una sección o un punto.
//   solo: 'bess'                     → una bandera del contexto (bess, plomo, mayor, costera)
//   solo: ['diesel', 'gasolina']     → solo para esos combustibles
// Sin `solo`, siempre se muestra. Un combustible que no se conoce todavía muestra los
// puntos comunes y esconde los específicos: mejor preguntar de menos que inventar.
export function aplica(item, ctx = {}) {
  const s = item?.solo
  if (!s) return true
  if (Array.isArray(s)) return !!ctx.combustible && s.includes(ctx.combustible)
  return !!ctx[s]
}

export function seccionesVisibles(formato, ctx = {}) {
  return formato
    .filter(s => aplica(s, ctx))
    .map(s => ({ ...s, puntos: puntosDe(s).filter(p => aplica(p, ctx)) }))
    .filter(s => s.puntos.length > 0)
}

export const respuesta = (datos, clave) => datos?.puntos?.[clave] || null

// "4 de 6" por sección, para el contador del encabezado plegado.
export function avanceSeccion(datos, seccion) {
  const puntos = puntosDe(seccion)
  const hechos = puntos.filter(p => respuesta(datos, p.clave)?.v).length
  return { hechos, total: puntos.length, completa: hechos === puntos.length }
}

// La regla del formato: un punto de SEGURIDAD en "Malo" sin control compensatorio escrito
// suspende el servicio. Es la misma comprobación que hace el trigger en la base; aquí se
// adelanta para poder decirlo antes de que el cierre falle.
export function seguridadSinControl(datos, formato = FORMATO_SOLAR) {
  const seccion = formato.find(s => s.bloquea)
  if (!seccion) return []
  return puntosDe(seccion)
    .filter(p => {
      const r = respuesta(datos, p.clave)
      return r?.v === 'M' && String(r.obs ?? '').trim() === ''
    })
    .map(p => p.clave)
}

// El formato pide que todo punto "Malo" quede documentado con fotografía.
export function malosSinFoto(datos, formato = FORMATO_SOLAR) {
  const claves = []
  for (const s of formato) {
    for (const p of puntosDe(s)) {
      const r = respuesta(datos, p.clave)
      if (r?.v === 'M' && !(r.fotos?.length > 0)) claves.push(p.clave)
    }
  }
  return claves
}

// Veredicto de un string a partir de lo medido. Se PROPONE: el técnico lo confirma.
// Aislamiento por debajo de 1 MΩ no pasa; una Voc que se aleja más del 10% de la teórica
// no condena el string, pide revisarlo.
export function veredictoString(s) {
  const n = v => (v === '' || v === null || v === undefined ? null : Number(v))
  const aisla = [n(s?.aisl_pos), n(s?.aisl_neg)].filter(v => v !== null && Number.isFinite(v))
  if (aisla.some(v => v < 1)) return 'no_pasa'
  const teorico = n(s?.voc_teorico)
  const medido = n(s?.voc_medido)
  if (teorico && medido && Math.abs(medido - teorico) / teorico > 0.1) return 'revisar'
  if (aisla.length === 0 || medido === null) return null
  return 'pasa'
}

// Qué dictamen propone la revisión. Solo es una propuesta: el técnico decide.
export function dictamenSugerido(datos, formato = FORMATO_SOLAR) {
  let hayMalo = false
  let hayRegular = false
  for (const s of formato) {
    for (const p of puntosDe(s)) {
      const v = respuesta(datos, p.clave)?.v
      if (v === 'M') { if (s.bloquea) return 'no_aprobado'; hayMalo = true }
      if (v === 'R') hayRegular = true
    }
  }
  if (hayMalo) return 'no_aprobado'
  if (hayRegular) return 'condicionado'
  return 'aprobado'
}

// Lo que falta antes de poder cerrar, en palabras. Vacío = se puede cerrar.
export function loQueFalta(datos, formato = FORMATO_SOLAR, opciones) {
  const faltas = []
  const sinControl = seguridadSinControl(datos, formato)
  if (sinControl.length) {
    faltas.push(`Seguridad sin resolver en ${sinControl.join(', ')}: escribe el control compensatorio o suspende el servicio.`)
  }
  const sinFoto = malosSinFoto(datos, formato)
  if (sinFoto.length) {
    faltas.push(`Falta la foto de ${sinFoto.join(', ')}: todo punto en "Malo" se documenta con fotografía.`)
  }
  for (const s of seccionesVisibles(formato, opciones)) {
    const a = avanceSeccion(datos, s)
    if (!a.completa) faltas.push(`${s.titulo}: faltan ${a.total - a.hechos} de ${a.total}.`)
  }

  const med = datos?.mediciones || {}
  if (formato === FORMATO_GENERADOR) {
    const hayLecturas = Object.values(med.lecturas || {}).some(l => l?.vacio || l?.carga)
    if (!hayLecturas) faltas.push('Mediciones: falta la prueba de funcionamiento.')
  } else if ((med.strings || []).length === 0) {
    faltas.push('Mediciones: no capturaste ningún string.')
  }

  if (!datos?.dictamen) faltas.push('Falta el dictamen del servicio.')
  return faltas
}
