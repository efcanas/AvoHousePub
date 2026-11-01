CREATE OR REPLACE FUNCTION public.ahtv_generar_clave_acceso()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_words text[] := ARRAY[
    'acceso','acordeon','agua','aguacate','ahbar','ahclub','ahmenu','ahmusic','ahpub','ahtv',
    'ajo','albahaca','alegria','ambiente','amiga','amigo','arepa','aroma','arroz','artista',
    'avo','avohouse','azucar','bachata','baile','bajo','bambu','banco','bar','barra',
    'barril','bateria','bodega','bolero','bongos','bosque','botella','brandy','brindis','brisa',
    'cacao','cactus','cafe','camaron','canasta','cancion','canela','cantante','canto','carta',
    'cava','cebada','cebolla','cereza','cero','cerveza','ceviche','champana','cinco','clave',
    'cliente','cocina','coco','coctel','codigo','combo','comedor','comino','conga','copa',
    'corcho','coro','cuatro','cuenta','cumbia','diez','disco','dj','dos','dulce',
    'empanada','ensalada','entrada','equipo','espuma','etiqueta','familia','fiesta','flor','fresa',
    'gaseosa','ginebra','grupo','guayaba','guitarra','helado','hielo','hoja','house','jardin',
    'jarra','jazmin','jugo','lampara','lata','laurel','letrero','licor','limon','limonada',
    'local','logo','luces','lulo','lupulo','maiz','malta','mambo','mango','manzana',
    'maraca','maracuya','marca','martini','melodia','menta','menu','merengue','mesa','mesero',
    'mezcla','miel','mojito','mora','musica','nacho','naranja','negocio','neon','nevera',
    'noche','nueve','ocho','oregano','orquesta','palma','palmera','pan','pantalla','papa',
    'papaya','parche','pareja','parlante','patacon','patio','pedido','pescado','piano','picada',
    'pimienta','pina','pista','pizza','planta','plantas','platano','playlist','pollo','premio',
    'promo','propina','puerta','pulpa','puntos','qr','queso','recuerdo','refresco','regalo',
    'reserva','reunion','ritmo','romero','ron','rumba','sabor','sal','salon','salsa',
    'sandwich','sangria','saxofon','seis','semilla','serenata','servicio','show','siete','silla',
    'sirope','soda','sol','sombra','son','sonero','sonido','sonrisa','tabla','tambor',
    'tapa','tarima','tarjeta','tequila','terraza','tierra','timba','timbal','tomate','tonica',
    'torta','tostada','trago','tres','trompeta','tropical','uno','uva','vaso','ventana',
    'verde','vermut','video','vinilo','vino','visita','vodka','whisky','yuca'
  ];

  v_size integer := cardinality(v_words);
  v_range constant bigint := 16777216; -- 2^24: todos los valores posibles de 3 bytes
  v_limit bigint;
  v_bytes bytea;
  v_random_value bigint;
  v_indexes integer[] := ARRAY[]::integer[];
  v_i integer;
BEGIN
  IF v_size <> 239 THEN
    RAISE EXCEPTION 'La biblioteca de claves AHtv debe contener 239 palabras; contiene %.', v_size;
  END IF;

  v_limit := (v_range / v_size) * v_size;

  -- Muestreo por rechazo: cada índice tiene exactamente la misma probabilidad.
  FOR v_i IN 1..3 LOOP
    LOOP
      v_bytes := extensions.gen_random_bytes(3);
      v_random_value :=
          get_byte(v_bytes, 0)::bigint * 65536
        + get_byte(v_bytes, 1)::bigint * 256
        + get_byte(v_bytes, 2)::bigint;
      EXIT WHEN v_random_value < v_limit;
    END LOOP;

    v_indexes := array_append(
      v_indexes,
      (v_random_value % v_size)::integer + 1
    );
  END LOOP;

  RETURN v_words[v_indexes[1]] || '-' ||
         v_words[v_indexes[2]] || '-' ||
         v_words[v_indexes[3]];
END;
$function$;
