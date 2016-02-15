-------------------------------------------
-- Remi Cura, Thales IGN, 2016
--
-- a tool to edit Z in QGIS
-- we propose ot edit Z in qgis trough a proxy geometry
-------------------------------------------


-- creating a dedicated schema
CREATE SCHEMA IF NOT EXISTS edit_Z  ;

SET search_path to edit_Z, public, rc_lib;

--create a parameter table : 
CREATE TABLE IF NOT EXISTS edit_Z_parameters
		(
		  gid SERIAL PRIMARY KEY ,
		  parameter_name text UNIQUE ,
		  parameter_value float NOT NULL, 
		  parameter_description text NOT NULL 
		); 
		TRUNCATE edit_Z_parameters CASCADE; 

INSERT INTO edit_Z_parameters (parameter_name, parameter_value, parameter_description)
VALUES ('display_range_max', 	1, 	 'the slope curve will be scaled by this factor')  ;
 

DROP FUNCTION IF EXISTS  rc_get_param(param_name text);
CREATE OR REPLACE FUNCTION  rc_get_param(param_name text) RETURNS float AS 
	$BODY$
		DECLARE      
			_r record;  
		BEGIN 
			SELECT * into _r
			FROM edit_Z_parameters
			WHERE  lower(parameter_name) = trim(both from lower(param_name));   
			RETURN _r.parameter_value ; 
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 

SELECT *
FROM  rc_get_param('display_range_max'::text) ;


--  create a test table of geometry :
DROP TABLE IF EXISTS line_Z ;
CREATE TABLE line_Z (
gid serial primary key
, line_Z geometry(LINESTRINGZ,0)
, line_alti geometry(LINESTRINGZ,0)
, line_slope geometry(LINESTRINGZM,0)
,min_Z float
) ;
CREATE INDEX ON line_Z USING GIST(line_Z) ; 
CREATE INDEX ON line_Z USING GIST(line_alti) ; 
CREATE INDEX ON line_Z USING GIST(line_slope) ; 



 
--creating
-- computing the Z = f(curv_abs)

/*
DROP TABLE IF EXISTS test;
CREATE TABLE test AS 
	WITH idata AS (
		SELECT 
			-- ST_SetPoint(line_alti,3,ST_Translate(ST_PointN(line_alti,4),0,0,2)) AS line_alti --update case
			-- ST_RemovePoint(line_alti,3) AS line_alti --delete case
			 ST_AddPoint(line_alti,ST_Centroid(ST_Collect(ST_PointN(line_alti,4),ST_PointN(line_alti,3)) ) , 3) as line_alti--insert case
			, line_Z AS old_line_Z
		FROM line_Z
	)
	SELECT  row_number() over() as gid,  f.*
	FROM idata, rc_alti_to_zgeom(line_alti,old_line_Z) AS f
*/
	 
DROP FUNCTION IF EXISTS  edit_Z.rc_alti_to_zgeom(geometry,geometry);
CREATE OR REPLACE FUNCTION  edit_Z.rc_alti_to_zgeom(line_alti geometry, old_line_Z geometry, out new_line_Z geometry)  AS 
	$BODY$ 
	/** for each points in alti, map this point to ppint in old line Z using curv abs and tolerance
		for points disapering, remove the point (@TODO)
		for points apperaring, add the point, do nothing (@TODO)
		for points changing their Z value, update those
		return updated line_z
	*/
		DECLARE       
		BEGIN  
		WITH idata AS (
			SELECT  line_alti,  old_line_Z 
		)
		, zmin AS (
			SELECT ST_ZMin( idata.old_line_Z) as zmin
			FROM idata
		)
		, points_alti AS (
			SELECT dmp.path AS alti_path, dmp.geom AS point_alti, ST_LineLocatePoint(idata.old_line_Z,dmp.geom) as alti_curvabs
			FROM idata, ST_DumpPoints(idata.line_alti) as dmp 
		)
		 , points_old_line_Z AS (
			SELECT dmp.path as line_Z_path, dmp.geom AS point_line_Z, ST_LineLocatePoint(idata.old_line_Z,dmp.geom) as line_Z_curvabs
			FROM idata, ST_DumpPoints(idata.old_line_Z) as dmp 
		)
		,map_l AS (
			SELECT alti_path, point_alti, alti_curvabs
				 , line_Z_path, point_line_Z,  line_Z_curvabs 
			FROM points_alti LEFT outer join points_old_line_Z ON ( Abs(alti_curvabs-line_Z_curvabs)< 10^(-6) ) 
		)
		,map_r AS (
			SELECT alti_path, point_alti, alti_curvabs
				 , line_Z_path, point_line_Z,  line_Z_curvabs 
			FROM points_alti RIGHT outer join points_old_line_Z ON ( Abs(alti_curvabs-line_Z_curvabs)< 10^(-6) ) 
		)
		,map aS (
			SELECT * FROM map_l UNION SELECT * FROM map_r
		)
		, new_point AS (
			SELECT line_z_path
				, ST_MakePoint(ST_X(np),ST_Y(np), ST_Y(point_alti) + zmin) as new_point --replacin Z by actual valueof alti_curvabs : 
				, alti_curvabs -- replacing line_z_curvabs by alti_curvabs
			FROM idata, zmin, map , ST_LineInterpolatePoint(idata.old_line_Z, alti_curvabs) as np
			WHERE alti_curvabs IS NOT NULL -- point is missing in alti, removing the corresponding line_z point; 
		)
		SELECT ST_MakeLine(new_point ORDER BY alti_curvabs ASC) INTO new_line_Z
		FROM new_point ; 
		RETURN ;
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 


DROP FUNCTION IF EXISTS  edit_Z.rc_zgeom_to_alti(geometry);
CREATE OR REPLACE FUNCTION  edit_Z.rc_zgeom_to_alti(igeom geometry, out line_alti geometry)  AS 
	$BODY$
		/** For each successive pairs of points, compute slope, 
		*/
		DECLARE       
		BEGIN 
			WITH points AS (
				SELECT dmp.path, dmp.geom
				FROM ST_DumpPoints(igeom) as dmp
			),
			zmin AS (
				SELECT ST_ZMin( igeom) as zmin
			)
			SELECT ST_MakeLine(ST_MakePoint(ST_X(geom), ST_Z(geom) - zmin, ST_y(geom)) ORDER BY path ASC) INTO line_alti 
			FROM zmin, points ; 
			RETURN ; 
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 

DROP FUNCTION IF EXISTS  edit_Z.rc_alti_to_slope(geometry);
CREATE OR REPLACE FUNCTION  edit_Z.rc_alti_to_slope(igeom geometry, out line_slope geometry)  AS 
	$BODY$
		/** For each successive pairs of points, compute slope, 
		*/
		DECLARE       
		BEGIN 
			WITH input_data AS (
				SELECT igeom 
			)
			, points AS (
				SELECT dmp.path , dmp.geom
				FROM input_data, st_dumppoints(input_data.igeom) AS dmp

			)
			, successive_pairs AS (
				SELECT path ,geom
					, COALESCE(ST_Azimuth( lag( geom , 1, NULL) OVER (ORDER By path), geom),pi()/2.0) as az
					, ST_Centroid(ST_Collect(ARRAY[lag( geom , 1, NULL) OVER (ORDER By path), geom]) )as avg_x
				FROM points  
			)
			 , slope AS (
				SELECT path, geom,  (1.0-2.0*az /pi() )*100.0 As slope
					,avg_x
				FROM successive_pairs
			)
			SELECT ST_MakeLine(ST_MakePoint(ST_X(avg_x), slope/100.0, ST_Y(geom),  ST_Z(geom)) ORDER BY path asc) INTO line_slope
			FROM slope ; 
			RETURN ; 
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 




 --populating with test line
TRUNCATE line_Z ;
INSERT INTO line_Z (line_Z, line_alti, line_slope,min_Z)
WITH series AS (
	SELECT s, ST_MakePoint(s + random()/2, 0, 10 +random()*2) AS pt
	FROM generate_series(1,100) AS s
)
, line AS (
SELECT ST_MakeLine(pt ORDER  BY s ASC) as line 
FROM series 
)
, min_Z AS (
	SELECT min(ST_Z(dmp.geom))  as min_Z
	FROM line, st_dumpPoints(line) as dmp
)
SELECT line,   line_alti,  rc_alti_to_slope(line_alti)  , min_Z
FROM min_Z,  line , rc_zgeom_to_alti(line) AS line_alti;




-- defining a trigger, so that all geometric fields of line_Z are in sync
CREATE OR REPLACE FUNCTION edit_Z.rc_correct_Z_for_line_Z()
  RETURNS  trigger  AS
$BODY$  -- have to correct qgis input, that put Z to 0 when editing line_Z, shame
		DECLARE  
		BEGIN  
			if TG_OP = 'DELETE' OR TG_OP = 'INSERT' THEN 
			--do nothing
			RAISE EXCEPTION 'not implemented yet' ; 
			ELSE --update
				
				IF ST_Equals (OLD.line_Z, NEW.line_Z)= FALSE THEN
					--we are going to correct the Z value inserted by QGIS
					-- we look for new points, then estimate correct new point using ST_InterpolatePoint 
				RAISE WARNING  'for the moment (QGIS < 2.12), inserted points in line have a Z to 0, which is not trivial to correct because we dont know which point(s) have been inserted and where, while other points might have been deleted, and other moved!';

					WITH idata AS (
						SELECT OLD.line_Z AS old_line_Z, 
						NEW.line_Z AS line_Z
					)
					 , points_line_Z AS (
						SELECT dmp.path as line_Z_path, dmp.geom AS point_line_Z, ST_LineLocatePoint(idata.old_line_Z,dmp.geom) as line_Z_curvabs
						FROM idata, ST_DumpPoints(idata.line_Z) as dmp 
					)
					SELECT ST_MakeLine(St_MakePoint(ST_X(point_line_Z), ST_Y(point_line_Z), ST_Z(pt) ) ORDER BY line_Z_path ASC)INTO NEW.line_Z
					FROM points_line_Z, idata, ST_LineInterpolatePoint(old_line_Z, line_Z_curvabs) as pt ;
								
				END IF;  
			END IF ;  
		RETURN  NEW;
		END;  
		$BODY$
  LANGUAGE plpgsql VOLATILE;

DROP TRIGGER IF EXISTS  rc_correct_Z_for_line_Z ON edit_Z.line_Z; 
CREATE  TRIGGER rc_correct_Z_for_line_Z   BEFORE  UPDATE OR INSERT  
    ON edit_Z.line_Z
 FOR EACH ROW 
    EXECUTE PROCEDURE edit_Z.rc_correct_Z_for_line_Z(); 

    
-- defining a trigger, so that all geometric fields of line_Z are in sync
CREATE OR REPLACE FUNCTION edit_Z.rc_update_line_Z()
  RETURNS  trigger  AS
$BODY$  
		DECLARE  
		BEGIN  
			if TG_OP = 'DELETE' OR TG_OP = 'INSERT' THEN 
			--do nothing
			RAISE EXCEPTION 'not implemented yet' ; 
			ELSE --update

				IF ST_Equals (OLD.line_Z, NEW.line_Z)= FALSE THEN
				--sync line_alti and line_slope
					--RAISE EXCEPTION 'changement dans line_Z' ; 
					NEW.line_alti = edit_Z.rc_zgeom_to_alti(NEW.line_Z) ;
					NEW.line_slope = edit_Z.rc_alti_to_slope(NEW.line_alti) ;
				ELSIF ST_Equals (OLD.line_alti, NEW.line_alti)= FALSE THEN
				--sync line_Z, then the others
					NEW.line_Z = edit_Z.rc_alti_to_zgeom(NEW.line_alti  , OLD.line_Z ) ;
					NEW.line_alti = edit_Z.rc_zgeom_to_alti(NEW.line_Z) ;
					NEW.line_slope = edit_Z.rc_alti_to_slope(NEW.line_alti) ;
				ELSIF ST_Equals (OLD.line_slope, NEW.line_slope)= FALSE THEN
				--sync line_Z, then the others
					RAISE EXCEPTION 'ERROR : not allowed to change slop yet (not implemented), change alti or Z values' ;
				END IF;  
			END IF ;  
		RETURN  NEW;
		END;  
		$BODY$
  LANGUAGE plpgsql VOLATILE;

DROP TRIGGER IF EXISTS  rc_update_line_Z ON edit_Z.line_Z; 
CREATE  TRIGGER rc_update_line_Z   BEFORE  UPDATE OR INSERT OR DELETE
    ON edit_Z.line_Z
 FOR EACH ROW 
    EXECUTE PROCEDURE edit_Z.rc_update_line_Z(); 


/*
SELECT *
FROM line_Z
rc_generate_orthogonal_point(
	IN iline geometry
	, IN ipoint geometry
	, IN  width FLOAT
	,IN  support_line_size FLOAT
	,OUT opoint geometry
	 );
*/
