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
, line_alti geometry(LINESTRINGZM,0) -- Z store curv abs of points in line_Z, M store Z of original curve
, line_slope geometry(LINESTRINGZM,0) -- Z store curv abs of points in line_Z, M stores Z of original curve
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
			 ST_SetPoint(line_alti,0,ST_Translate(ST_PointN(line_alti,1),0,1)) AS line_alti --update case
			-- ST_RemovePoint(line_alti,3) AS line_alti --delete case
			-- ST_AddPoint(line_alti,ST_Centroid(ST_Collect(ST_PointN(line_alti,4),ST_PointN(line_alti,3)) ) , 3) as line_alti--insert case
			, line_Z AS old_line_Z
			, min_Z
		FROM line_Z
	)
	 , astext AS (
		SELECT ST_AsText(line_alti) AS line_alti
		,  ST_AsText(old_line_Z) AS line_z
	FROM idata
	)
	SELECT  row_number() over() as gid,  ST_AsText(f.new_line_z) ,ST_AsText( f.new_line_alti), f.new_min_z
	FROM idata, rc_alti_to_zgeom(line_alti,old_line_Z,min_Z) AS f
*/
	 
DROP FUNCTION IF EXISTS  edit_Z.rc_alti_to_zgeom(geometry,geometry, float);
CREATE OR REPLACE FUNCTION  edit_Z.rc_alti_to_zgeom(line_alti geometry, old_line_Z geometry, old_min_z float, out new_line_Z geometry, out new_line_alti geometry, OUT new_min_z float)  AS 
	$BODY$ 
	/** for each points in alti, map this point to ppint in old line Z using curv abs and tolerance
		for points disapering, remove the point (@TODO)
		for points apperaring, add the point, do nothing (@TODO)
		for points changing their Z value, update those
		return updated line_z
	*/
		DECLARE      
			_mapping_threshold float := pow(10,-2) ; 
			_support_line_size float := ST_Length(old_line_Z) / 100.0 ; 
			_r record; 
		BEGIN  
		-- @TODO @FIXME error : old Zmin should be used, and new_zmin should be returned
		WITH idata AS (
			SELECT  line_alti,  old_line_Z , old_min_z
		) 
		, points_alti AS (
			SELECT dmp.path AS alti_path, dmp.geom AS point_alti,  ST_Z(dmp.geom)as alti_curvabs
			FROM idata, ST_DumpPoints(idata.line_alti) as dmp 
		)
		 , points_old_line_Z AS (
			SELECT dmp.path as line_Z_path, dmp.geom AS point_line_Z, ST_LineLocatePoint(idata.old_line_Z,dmp.geom) as line_Z_curvabs
			FROM idata, ST_DumpPoints(idata.old_line_Z) as dmp 
		)
		,map_l AS (
			SELECT alti_path, point_alti, alti_curvabs
				 , line_Z_path, point_line_Z,  line_Z_curvabs 
			FROM points_alti LEFT outer join points_old_line_Z ON ( Abs(St_Z(point_alti)-line_Z_curvabs)< 0.0001) 
		)
		,map_r AS (
			SELECT alti_path, point_alti, alti_curvabs
				 , line_Z_path, point_line_Z,  line_Z_curvabs 
			FROM points_alti RIGHT outer join points_old_line_Z ON ( Abs(St_Z(point_alti)-line_Z_curvabs)< 0.0001 ) 
		)
		,map aS (
			SELECT * FROM map_l UNION SELECT * FROM map_r
		)
		 , line_Z_origin AS(
			SELECT map.*, St_Distance(point_alti, idata.old_line_Z)  + idata.old_min_z AS new_z
				, alti_path[1] != 1 AND   COALESCE(alti_curvabs ,0)=0 AS is_inserted
			FROM idata, map
		)
		, zmin AS (
			SELECT min(new_z) AS zmin
			FROM line_Z_origin
		)
		, new_point_regular AS ( -- for missing points, dont consider ; for inserted point, add new ; for updated point, consider new
			SELECT   
					ST_MakePoint(ST_X(point_line_z),ST_Y(point_line_z),  new_z )  as new_point --replacin Z by actual valueof alti_curvabs : 
				, line_z_curvabs -- replacing line_z_curvabs by alti_curvabs
			FROM line_Z_origin, zmin 
			WHERE alti_curvabs IS NOT NULL -- point is missing in alti, removing the corresponding line_z point; 
				AND is_inserted = FALSE
		)
		, new_point_insert AS (
			SELECT  
					ST_MakePoint(ST_X(np),ST_Y(np),  new_z )  as new_point --replacin Z by actual valueof alti_curvabs : 
				, ST_LineLocatePoint( idata.old_line_Z, np ) AS line_z_curvabs-- replacing line_z_curvabs by alti_curvabs
			FROM line_Z_origin, idata, zmin,   ST_ClosestPoint( idata.old_line_Z, point_alti) as np
			WHERE alti_curvabs IS NOT NULL -- point is missing in alti, removing the corresponding line_z point; 
				AND is_inserted = TRUE
		)
		, unioned AS (
			SELECT * FROM new_point_regular UNION SELECT *
			FROM new_point_insert 
		)
		, n_line_Z AS (
		SELECT  ST_MakeLine(new_point ORDER BY line_z_curvabs ASC) AS n_line_
		FROM unioned 
		) 
		, n_alti_origin AS (
			SELECT ST_MakeLine(ST_MakePoint( line_z_curvabs,2 * (St_Z(new_point)-zmin) , line_z_curvabs, St_Z(new_point)) ORDER BY  line_z_curvabs ASC ) as n_alti_origin
			FROM zmin, unioned
		)
		, n_alti_  AS (
			SELECT f.composated as n_alti
			FROM n_line_Z, n_alti_origin, rc_composate_curves(n_line_, n_alti_origin ,_support_line_size ) As f   
		)
		SELECT n_line_, n_alti, zmin  INTO _r
		FROM n_line_Z, n_alti_ , zmin;  
		new_line_Z := _r.n_line_ ; 
		new_line_alti := _r.n_alti;
		new_min_Z := _r.zmin ; 


		
		-- RAISE EXCEPTION 'new_line_Z  %, new_line_alti %', ST_Astext(new_line_Z) , ST_Astext(new_line_alti) ; 
		RETURN ;
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 


DROP FUNCTION IF EXISTS  edit_Z.rc_zgeom_to_alti(geometry);
CREATE OR REPLACE FUNCTION  edit_Z.rc_zgeom_to_alti(igeom geometry, out line_alti geometry, out new_z_min float)  AS 
	$BODY$
		/** For each successive pairs of points, compute slope, (a new curve, origin base), then composte to be in the zgeom referential
		*/
		DECLARE
			_support_line_size FLOAT :=  ST_Length(igeom)/100.0 ; 
		BEGIN 
			WITH points AS (
				SELECT dmp.path, dmp.geom, ST_LineLocatePoint(igeom, dmp.geom) AS curvabs
				FROM ST_DumpPoints(igeom) as dmp
			),
			zmin AS (
				SELECT ST_ZMin( igeom) as zmin
			)
			, alti_origin AS (
				SELECT ST_MakeLine(ST_MakePoint(curvabs,2*( ST_Z(geom) - zmin)  , curvabs,ST_Z(geom) ) ORDER BY path ASC) AS alti_origin
				FROM zmin, points 
			)
			-- , compositing AS (
			SELECT f.*, zmin INTO line_alti ,new_z_min
			FROM zmin, alti_origin, rc_composate_curves(igeom, alti_origin ,_support_line_size ) As f  ; 
			
			RETURN ; 
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT; 

DROP FUNCTION IF EXISTS  edit_Z.rc_zgeom_to_slope( geometry);
CREATE OR REPLACE FUNCTION  edit_Z.rc_zgeom_to_slope(  line_Z geometry, out line_slope geometry)  AS 
	$BODY$
		/** For each successive pairs of points, compute slope, then apply it as offset to construct 
		*/
		DECLARE  
			_support_line_size FLOAT :=  ST_Length(line_Z)/100.0 ; 
		BEGIN 
			WITH input_data AS (
				SELECT line_Z , ST_Length(line_Z) AS length
			)
			, points AS (
				SELECT dmp.path , dmp.geom, ST_LineLocatePoint(input_data.line_Z, dmp.geom) AS curvabs
				FROM input_data, st_dumppoints(input_data.line_Z) AS dmp

			)
			, pure_Z AS (
				SELECT path,curvabs,  ST_Makepoint(curvabs * input_data.length , ST_Z(geom)) as point_original_length
					,  ST_Makepoint(curvabs , ST_Z(geom)) as point_pureZ
				FROM input_data , points
			)
			, successive_pairs AS (
				SELECT path ,curvabs
					, COALESCE(ST_Azimuth( lag( point_original_length , 1, NULL) OVER (ORDER By path), point_original_length),pi()/2.0) as az
					, ST_Centroid(ST_Collect(ARRAY[lag( point_pureZ , 1, NULL) OVER (ORDER By path), point_pureZ]) )as avg_x
				FROM  pure_Z  
			)
			 , slope AS (
				SELECT  ST_MakeLine(ST_MakePoint(  ST_X(avg_x), 2*( 1.0-2.0*az /pi()) , curvabs , ST_X(avg_x)/length)  ORDER BY path asc) as slope_origine
				FROM input_data ,successive_pairs
			)
			SELECT f.* INTO line_slope
			FROM input_data, slope, rc_composate_curves(input_data.line_Z, slope_origine ,_support_line_size ) As f   ; 
			RETURN ; 
		END ;  
	$BODY$
LANGUAGE plpgsql STABLE STRICT;  

DROP TABLE IF EXISTS test_line_Z;
CREATE TABLE test_line_Z(
gid serial primary key
, line_Z geometry(linestring ,0)
) ; 
 
TRUNCATE test_line_Z ; 
INSERT INTO test_line_Z VALUES
(1,ST_GeomFromText('LINESTRING(-18 -28,17 -25,42 -14,48 -6)')),
(2,ST_GeomFromText('LINESTRING(-26 -26,-41 -38,-49 -65,-51 -80,-67 -90)')),
(3,ST_GeomFromText('LINESTRING(-22 -31,-7 -61,5 -84,15 -118)')),
(4,ST_GeomFromText('LINESTRING(-22 -19,-44 24,-78 44,-90 50)')),
(5,ST_GeomFromText('LINESTRING(-101 29,-96 -12,-91 -34,-85 -62,-75 -82,-72 -87)')),
(6,ST_GeomFromText('LINESTRING(49 -5,61 -58,54 -87,43 -106,29 -116,19 -120)')),
(7,ST_GeomFromText('LINESTRING(-94 50,-101 43,-104 39,-104 33)')),
(8,ST_GeomFromText('LINESTRING(-26 -32,-33 -68,-36 -116,-44 -158,-64 -196,-65 -206)')),
(9,ST_GeomFromText('LINESTRING(-70 -93,-80 -105,-83 -127,-78 -155,-71 -173,-76 -195,-72 -206,-68 -205)')),
(10,ST_GeomFromText('LINESTRING(13 -131,15 -158,7 -187,-18 -202,-34 -209,-50 -210,-60 -211,-64 -211)')),
(11,ST_GeomFromText('LINESTRING(21 -126,125 -170,143 -183,211 -171,237 -120)')) ; 
DELETE FROM test_line_Z WHERE gid != 11 ; 
TRUNCATE line_Z ;
WITH ori_2D AS (
	SELECT gid, dmp.path, ST_Translate(point,0,0,random() *5 ) AS pt
	FROM test_line_Z, ST_DumpPoints(line_Z)AS dmp, ST_Force3DZ(dmp.geom) AS point
)
, lines_3D AS (
	SELECT gid, ST_MakeLine(pt ORDER BY path ASC) AS line 
	FROM ori_2D
	GROUP BY gid
)
INSERT INTO line_Z (gid, line_Z )
SELECT gid, line 
FROM  lines_3D ; 

/*
 --populating with test line
TRUNCATE line_Z ;
INSERT INTO line_Z (line_Z, line_alti, line_slope,min_Z)
WITH series AS (
	SELECT s, ST_MakePoint( s +random()/2.0,s/2.0, CASE WHEN s=0 then 1 ELSE 3 END ) AS pt
	FROM generate_series(0,15) AS s
)
, line AS (
SELECT ST_MakeLine(pt ORDER  BY s ASC) as line 
FROM series 
) 
SELECT line,   f.line_alti,  rc_zgeom_to_slope(line)  , f.new_z_min
FROM  line , rc_zgeom_to_alti(line) AS f ;

*/
-------------------------------------------
/*
	WITH idata AS (
		SELECT   line_Z AS old_line_Z
			--, St_Astext(ST_SetPoint(line_alti,3,ST_Translate(ST_PointN(line_alti,4),0,2,0)) ) AS line_alti
			-- ,ST_RemovePoint(line_alti,3) AS line_alti --delete case
			 ,   ST_AddPoint(line_alti,ST_Force4D(ST_Force2D(ST_Centroid(ST_Collect(ST_PointN(line_alti,4),ST_PointN(line_alti,3)) ))) , 3) as line_alti--insert case	 
		FROM line_Z 
*/
		
-- defining a trigger, so that all geometric fields of line_Z are in sync
CREATE OR REPLACE FUNCTION edit_Z.rc_correct_Z_for_line_Z()
  RETURNS  trigger  AS
$BODY$  -- have to correct qgis input, that put Z to 0 when editing line_Z, shame
		DECLARE   
		BEGIN   
			if  TG_OP = 'INSERT' THEN 
			--do nothing
			RAISE EXCEPTION 'not implemented yet' ;  
			ELSE --update
				
				
				IF ST_Equals (OLD.line_Z, NEW.line_Z)= FALSE THEN
					--we are going to correct the Z value inserted by QGIS
					-- we look for new points, then estimate correct new point using ST_InterpolatePoint 
				RAISE WARNING  'for the moment (QGIS < 2.12), inserted points in line have a Z to 0, which is not trivial to correct because we dont know which point(s) have been inserted and where, while other points might have been deleted, and other moved!';

				/*
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
				*/
								
				END IF;  
			END IF ;  
		RETURN  NEW;
		END;  
		$BODY$
  LANGUAGE plpgsql VOLATILE;

DROP TRIGGER IF EXISTS  rc_correct_Z_for_line_Z ON edit_Z.line_Z; 
-- CREATE  TRIGGER rc_correct_Z_for_line_Z   BEFORE  UPDATE OR INSERT    ON edit_Z.line_Z
-- FOR EACH ROW   EXECUTE PROCEDURE edit_Z.rc_correct_Z_for_line_Z(); 

 
-- defining a trigger, so that all geometric fields of line_Z are in sync
CREATE OR REPLACE FUNCTION edit_Z.rc_update_line_Z()
  RETURNS  trigger  AS
$BODY$  
		DECLARE  
			_has_Z boolean := FALSE; 
			_r record ; 
		BEGIN   
			if  TG_OP = 'INSERT' THEN 
			--do nothing
				-- RAISE EXCEPTION 'not implemented yet' ; 
				SELECT min(ST_Z(dmp.geom)) IS NOT NULL INTO _has_Z
				FROM ST_DumpPoints(NEW.line_Z) AS dmp ;

				IF _has_Z IS FALSE THEN
					NEW.line_Z := ST_Force3D(NEW.line_Z);
					NEW.min_Z := 0 ; 
				END IF ; 
				SELECT * INTO NEW.line_alti, NEW.min_Z FROM rc_zgeom_to_alti(NEW.line_Z) ; 
				NEW.line_slope = rc_zgeom_to_slope(NEW.line_Z)  ;  
				
			ELSE --update

				IF OLD.line_Z::bytea !=  NEW.line_Z::bytea THEN
				--sync line_alti and line_slope
					--RAISE EXCEPTION 'changement dans line_Z' ; 
					SELECT * INTO NEW.line_alti, NEW.min_Z FROM edit_Z.rc_zgeom_to_alti(NEW.line_Z) ;
					NEW.line_slope = edit_Z.rc_zgeom_to_slope( NEW.line_Z) ;
				ELSIF ST_Equals (OLD.line_alti, NEW.line_alti)= FALSE THEN
				--sync line_Z, then the others
					SELECT * INTO  _r FROM  edit_Z.rc_alti_to_zgeom(NEW.line_alti  , OLD.line_Z, NEW.min_Z ) ; 
					NEW.line_Z := _r.new_line_Z ; NEW.line_alti := _r.new_line_alti ; NEW.min_Z := _r.new_min_Z ;
					NEW.line_slope := edit_Z.rc_zgeom_to_slope( NEW.line_Z) ;
					
				ELSIF ST_Equals (OLD.line_slope, NEW.line_slope)= FALSE THEN
				--sync line_Z, then the others
					RAISE EXCEPTION 'ERROR : not allowed to change slop yet (not implemented), change alti or Z values' ;
				END IF;  

				NEW.min_Z = St_Zmin(NEW.line_Z) ; 
			END IF ;  
		RETURN  NEW;
		END;  
		$BODY$
  LANGUAGE plpgsql VOLATILE;

DROP TRIGGER IF EXISTS  rc_update_line_Z ON edit_Z.line_Z; 
CREATE  TRIGGER rc_update_line_Z BEFORE UPDATE OR INSERT OR DELETE
    ON edit_Z.line_Z
 FOR EACH ROW 
    EXECUTE PROCEDURE edit_Z.rc_update_line_Z(); 


/*
SELECT *
FROM line_Z
 , rc_generate_orthogonal_point(
	IN iline geometry
	, IN icurvabs float
	, IN  width FLOAT
	,IN  support_line_size FLOAT)
	
*/
