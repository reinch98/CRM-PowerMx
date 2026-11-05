# Genera supabase/sql/95_kits_sin_bujias.sql desde REFACCIONAMIENTO GENERAC.xlsx.
# Uso: python scripts/generar_modelos_generac.py "<ruta del xlsx>"
#
# Lee las hojas Air Cooled y Liquid Cooled. Un kit = la combinación de filtro de aceite y filtro
# de aire de un modelo; solo lleva las piezas que ya están en el catálogo (CATALOGO). Las bujías
# no entran en los kits (Caña, 30/10/2026); su código sigue en `modelos_generador`.
# Los ids salen de uuid5 para que repetir el script no cree kits nuevos.
import re
import sys
import uuid
from pathlib import Path

import openpyxl

ESPACIO = uuid.UUID('6f1d2a54-94a1-4a54-9a31-0c94d0a7e001')
CATALOGO = {'070185ES', '0D5419', '0A45310244', '0E7080', '0D9723S', '0E9371AS', '0G5894',
            '0F5419', 'G059402'}
PIEZAS = ['Filtro de aceite', 'Filtro de aire']
HOJAS = {'Air Cooled': 'air_cooled', 'Liquid Cooled': 'liquid_cooled'}
NOMBRE = {'air_cooled': 'Air Cooled', 'liquid_cooled': 'Liquid Cooled'}

ENCABEZADO = """-- ===========================================================================
-- KITS DE MANTENIMIENTO SIN BUJÍAS
--
-- GENERADO por scripts/generar_modelos_generac.py. No editar a mano.
--
-- Caña pidió rehacer los kits de la 94 descartando las bujías: ahora un kit es el filtro de
-- aceite y el filtro de aire de los modelos que comparten esas dos piezas. El código de la bujía
-- se queda en `modelos_generador` como referencia.
--
-- Los kits de la 94 se borran con sus líneas (`on delete cascade`). Se puede repetir: no pisa
-- las piezas que el admin les agregue a los kits de aquí.
-- Prueba: 95_prueba_kits_sin_bujias.sql.
-- ===========================================================================
"""


def q(texto):
    return 'null' if texto is None else "'" + str(texto).replace("'", "''") + "'"


def codigo(valor):
    limpio = str(valor or '').strip().upper()
    return None if limpio in ('', 'N/A') else limpio


def leer(ruta):
    wb = openpyxl.load_workbook(ruta, data_only=True)
    modelos = {}
    for hoja, enfriamiento in HOJAS.items():
        for f in wb[hoja].iter_rows(min_row=5, values_only=True):
            if not f[0]:
                continue
            modelos[str(f[0]).strip().upper()] = {
                'kw': float(re.sub(r'[^0-9.]', '', str(f[1]))), 'enfriamiento': enfriamiento,
                'filtro_aceite': codigo(f[3]), 'filtro_aire': codigo(f[4])}
    return modelos


def main():
    modelos = leer(sys.argv[1])
    kits = {}
    for m in modelos.values():
        clave = (m['enfriamiento'], m['filtro_aceite'], m['filtro_aire'])
        m['kit'] = None
        if any(c in CATALOGO for c in clave[1:]):
            m['kit'] = str(uuid.uuid5(ESPACIO, 'sin-bujias|' + '|'.join(str(c) for c in clave)))
            kits.setdefault(clave, m['kit'])

    sal = [ENCABEZADO, 'begin;\n']
    ids = ', '.join(q(k) for k in sorted(kits.values()))
    sal.append(f'delete from paquetes_mantenimiento where kit and id not in ({ids});\n')

    for (enf, *codigos), kit in sorted(kits.items(), key=lambda x: str(x[0])):
        presentes = [c for c in codigos if c in CATALOGO]
        faltan = [f'{t.lower()} {c}' for t, c in zip(PIEZAS, codigos) if c and c not in CATALOGO]
        nota = 'Falta en el catálogo: ' + faltan[0] + '.' if faltan else 'Kit completo.'
        kws = [m['kw'] for m in modelos.values() if m['kit'] == kit]
        rango = f'{min(kws):g} kW' if min(kws) == max(kws) else f'{min(kws):g}–{max(kws):g} kW'
        # Dos kits pueden llevar la misma pieza del catálogo y faltarles otra distinta.
        pendiente = [c for c in codigos if c and c not in CATALOGO]
        cola = f' (falta {pendiente[0]})' if pendiente else ''
        nombre = f"Kit {NOMBRE[enf]} {rango} · {' + '.join(presentes)}{cola}"
        sal.append(f"insert into paquetes_mantenimiento (id, tipo, kit, nombre, notas) values "
                   f"({q(kit)}, 'menor', true, {q(nombre)}, {q(nota)}) "
                   f"on conflict (id) do update set nombre = excluded.nombre, notas = excluded.notas;")
        for orden, (titulo, c) in enumerate(zip(PIEZAS, codigos), 1):
            if c in CATALOGO:
                linea = uuid.uuid5(ESPACIO, f'{kit}|{c}')
                sal.append(f"insert into paquete_lineas (id, paquete_id, descripcion, producto_id, cantidad, orden) "
                           f"select {q(linea)}, {q(kit)}, {q(titulo)}, p.id, 1, {orden} "
                           f"from productos p where p.sku = {q(c)} on conflict (id) do nothing;")

    valores = ',\n'.join(f"({q(mod)}, {q(m['kit'])}::uuid)" for mod, m in sorted(modelos.items()))
    sal.append(f"\nupdate modelos_generador g set paquete_id = v.kit\n  from (values\n{valores}\n"
               f") v(modelo, kit)\n where g.modelo = v.modelo;\n")
    sal.append("insert into _migraciones (archivo, tipo) values ('95_kits_sin_bujias.sql', 'datos')\n"
               "  on conflict (archivo) do nothing;\n\ncommit;\n\nnotify pgrst, 'reload schema';\n")

    destino = Path(__file__).parent.parent / 'supabase' / 'sql' / '95_kits_sin_bujias.sql'
    destino.write_text('\n'.join(sal), encoding='utf-8', newline='\n')
    print(len(modelos), 'modelos,', len(kits), 'kits,', sum(1 for m in modelos.values() if not m['kit']), 'sin kit')


main()
