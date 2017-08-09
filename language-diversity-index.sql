-- Install the PostGIS extensions
CREATE EXTENSION postgis;

-- Create a custom Albers Equal Area projection for South Africa
INSERT INTO spatial_ref_sys (srid, proj4text)
VALUES (60000, '+proj=aea +lat_1=-25.5 +lat_2=-31.5 +lat_0=-28.5 +lon_0=24.5 +ellps=WGS84');

-- Load the south-africa.shp shapefile into a table named 'country' by running:
--   shp2pgsql -s 4326 south-africa.shp country | psql <database-name>

-- Create a version of the country polygon that is projected to our custom
-- projection, and simplified by the reduction of some detail
ALTER TABLE country ADD COLUMN geom_proj GEOMETRY(MultiPolygon,60000);
UPDATE country SET geom_proj = ST_SimplifyPreserveTopology(ST_Transform(geom, 60000), 500);

-- Get the bounding box of the countrt.
select floor(st_xmin(geom_proj)) as west,
	floor(st_ymin(geom_proj)) as south,
	ceil(st_xmax(geom_proj)) as east,
	ceil(st_ymax(geom_proj)) as north
from country;

-- The result looks like:
--
--   west   |  south  |  east  | north
-- ---------+---------+--------+--------
--  -785422 | -709476 | 832418 | 694290

-- Load the small area shapefile into a table named 'imp_sal' by running:
--   shp2pgsql -s 4326 -D SAL_APRI.SHP imp_sal | psql <database-name>

-- Create a new table for the small areas with only the details we need.
CREATE TABLE sal (
	gid SERIAL PRIMARY KEY,
	code CHAR(7) UNIQUE,
	geom GEOMETRY(MultiPolygon,4326),
	geom_proj GEOMETRY(MultiPolygon,60000),
	area FLOAT,
	pop INT
);
CREATE INDEX sal_geom_gist ON sal USING gist(geom);
CREATE INDEX sal_geom_proj_gist ON sal USING gist(geom_proj);

-- Load the 'sal' table from 'imp_sal'
INSERT INTO sal (code, geom, geom_proj)
SELECT sal_code::CHAR(7), geom, ST_Transform(geom, 60000) 
FROM imp_sal;

-- Get rid of the 'imp_sal' table which we don't need any more.
DROP TABLE imp_sal;

-- Fix broken geometries
UPDATE sal SET geom_proj = ST_Multi(ST_MakeValid(geom_proj)) WHERE NOT ST_IsValid(geom_proj);

-- Calculate areas
UPDATE sal SET area = ST_Area(geom_proj);

-- Set up list of languages
CREATE TABLE language (
	id INT PRIMARY KEY,
	name VARCHAR
);

INSERT INTO language (id, name)
VALUES (1, 'Afrikaans'),
	(2, 'English'),
	(3, 'isiNdebele'),
	(4, 'isiXhosa'),
	(5, 'isiZulu'),
	(6, 'Sepedi'),
	(7, 'Sesotho'),
	(8, 'Setswana'),
	(9, 'Sign language'),
	(10, 'siSwati'),
	(11, 'Tshivenḓa'),
	(12, 'Xitsonga');

-- Load the census language file into a temporary table ("wide" format unfortunately)
CREATE TEMP TABLE imp_lang (
	sal_code char(7) primary key,
	afr int, eng int, nde int, xho int, zul int, ped int, sot int, tsw int, sig int,
	swa int, ven int, tso int, oth int, uns int, nap int
);
\COPY imp_lang FROM 'sal-lang.csv' WITH CSV HEADER

-- Transfer language data into "long" format table
CREATE TABLE sal_lang (
	sal_gid INT,
	lang_id INT,
	pop INT,
	PRIMARY KEY (sal_gid, lang_id)
);

INSERT INTO sal_lang SELECT sal.gid, 1, afr FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 2, eng FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 3, nde FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 4, xho FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 5, zul FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 6, ped FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 7, sot FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 8, tsw FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 9, sig FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 10, swa FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 11, ven FROM imp_lang JOIN sal ON sal_code = sal.code;
INSERT INTO sal_lang SELECT sal.gid, 12, tso FROM imp_lang JOIN sal ON sal_code = sal.code;

-- Create a table to contain the hexagonal grid
CREATE TABLE grid (
	gid SERIAL PRIMARY KEY,
	geom_proj GEOMETRY(MultiPolygon, 60000)
);
CREATE INDEX grid_geom_proj_gist ON grid USING gist(geom_proj);

-- Function to generate the hexagon grid, slightly modified from http://rexdouglass.com/spatial-hexagon-binning-in-postgis/
CREATE OR REPLACE FUNCTION genhexagons(width float, xmin float, ymin float, xmax float, ymax float)
RETURNS float AS $total$
declare
	b float := width/2;
	a float := b/sqrt(3);
	c float := 2*a;
	height float := 2*(a+c);
	ncol float :=ceil(abs(xmax-xmin)/width);
	nrow float :=ceil(abs(ymax-ymin)/height);

	polygon_string varchar := 'POLYGON((' ||
	                                    0 || ' ' || 0     || ' , ' ||
	                                    b || ' ' || a     || ' , ' ||
	                                    b || ' ' || a+c   || ' , ' ||
	                                    0 || ' ' || a+c+a || ' , ' ||
	                                 -1*b || ' ' || a+c   || ' , ' ||
	                                 -1*b || ' ' || a     || ' , ' ||
	                                    0 || ' ' || 0     ||
	                            '))';
BEGIN
    INSERT INTO grid (geom_proj) SELECT st_multi(st_translate(the_geom, x_series*width+xmin, y_series*height+ymin))
    from generate_series(0, ncol::int , 1) as x_series,
    generate_series(0, nrow::int,1 ) as y_series,
    (
       SELECT st_setsrid(polygon_string::geometry, 60000) as the_geom
       UNION
       SELECT ST_Translate(st_setsrid(polygon_string::geometry, 60000), b , a+c)  as the_geom
    ) as two_hex;
    RETURN NULL;
END;
$total$ LANGUAGE plpgsql;

-- Generate the hexagon grid.
-- 8660.25403784439 = 10000 * sqrt(3)/2
-- Buffer it out by 5km
SELECT genhexagons(8660.25403784439,
	-785422 - 5000,
	-709476 - 5000,
	832418 + 5000,
	694290 + 5000);

-- Clip the grid to the boundaries of South Africa, and drop those cells fully outside
UPDATE grid
SET geom_proj = ST_Multi(ST_CollectionExtract(ST_Intersection(grid.geom_proj, country.geom_proj), 3))
FROM country;

DELETE FROM grid
WHERE st_isempty(geom_proj);

-- Calculate intersections between grid cells and small areas
CREATE TABLE isec (
	sal_gid int,
	grid_gid int,
	geom_proj geometry(multipolygon, 60000),
	frac_of_sal float,
	primary key(sal_gid, grid_gid)
);

INSERT INTO isec(sal_gid, grid_gid, geom_proj)
SELECT sal.gid, grid.gid, ST_Multi(ST_Intersection(sal.geom_proj, grid.geom_proj))
FROM sal JOIN grid ON sal.geom_proj && grid.geom_proj
WHERE ST_Intersects(sal.geom_proj, grid.geom_proj);

-- Calculate what fraction of the small area falls within each intersection
-- (so that we can divide population proportionally when a small area is split
-- over multiple grid cells).
UPDATE isec SET frac_of_sal = st_area(isec.geom_proj)/sal.area
FROM sal WHERE isec.sal_gid = sal.gid;

-- Calculate the language stats for each grid cell
CREATE TABLE grid_lang (
	grid_gid int,
	lang_id int,
	pop float,
	PRIMARY KEY (grid_gid, lang_id)
);

INSERT INTO grid_lang(grid_gid, lang_id, pop)
SELECT isec.grid_gid, sal_lang.lang_id,	SUM(sal_lang.pop * isec.frac_of_sal)
FROM isec JOIN sal_lang ON isec.sal_gid = sal_lang.sal_gid
GROUP BY isec.grid_gid, sal_lang.lang_id;
