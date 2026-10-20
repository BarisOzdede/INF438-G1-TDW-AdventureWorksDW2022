/* =====================================================================
   06_mesures.sql  —  Étape F2 : temps d'exécution de R1, R2, R3
                      dans les modèles TDW et SCD 2

   À exécuter après 02 → 03 → 04 (indépendant de 05 et 07).

   Protocole (consigne F2) :
     - SET STATISTICS TIME ON autour de chaque exécution mesurée
       (les temps CPU / écoulés de SQL Server apparaissent dans les
       messages) ;
     - en parallèle, le script chronomètre chaque exécution avec
       SYSDATETIME() et stocke la durée dans #Mesures ;
     - 1 exécution de chauffe (non retenue, met les pages en cache),
       puis 3 exécutions mesurées ; on retient la MÉDIANE ;
     - phase 1 sans index supplémentaire, phase 2 après création d'un
       index (clé du membre, FromDate, ToDate) sur les tables temporelles.

   Pour ne pas inonder la sortie, chaque requête écrit son résultat dans
   une table temporaire (SELECT ... INTO), supprimée aussitôt : le coût
   est le même pour les deux modèles.

   Remarque : les clés primaires (clé du membre, FromDate) sont déjà des
   index cluster ; l'index de la phase 2 ajoute ToDate et la colonne de
   valeur (INCLUDE) pour couvrir la jointure temporelle. Par symétrie,
   la copie SCD 2 reçoit l'index équivalent sur (ProductAlternateKey,
   StartDate, EndDate), la clé « membre » du modèle SCD 2.
   Les index sont laissés en place à la fin ; le script les supprime au
   début, il est donc réexécutable.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   0. Remise à l'état « sans index supplémentaire »
   --------------------------------------------------------------------- */
DROP INDEX IF EXISTS IX_ProduitSousCategorie_Intervalle ON tdw.ProduitSousCategorie;
DROP INDEX IF EXISTS IX_ProduitPrix_Intervalle          ON tdw.ProduitPrix;
DROP INDEX IF EXISTS IX_ProduitDureeVie_Intervalle      ON tdw.ProduitDureeVie;
DROP INDEX IF EXISTS IX_SousCategorieNom_Intervalle     ON tdw.SousCategorieNom;
DROP INDEX IF EXISTS IX_EmployeSupervision_Intervalle   ON tdw.EmployeSupervision;
DROP INDEX IF EXISTS IX_EmployeTerritoire_Intervalle    ON tdw.EmployeTerritoire;
DROP INDEX IF EXISTS IX_scd2_DimProduit_Intervalle      ON tdw_scd2.DimProduit;
GO

IF OBJECT_ID('tempdb..#Requetes') IS NOT NULL DROP TABLE #Requetes;
IF OBJECT_ID('tempdb..#Mesures')  IS NOT NULL DROP TABLE #Mesures;

CREATE TABLE #Requetes (
    Id      INT IDENTITY PRIMARY KEY,
    Requete NVARCHAR(5)   NOT NULL,
    Modele  NVARCHAR(10)  NOT NULL,
    Texte   NVARCHAR(MAX) NOT NULL
);

CREATE TABLE #Mesures (
    Phase    NVARCHAR(15) NOT NULL,
    Requete  NVARCHAR(5)  NOT NULL,
    Modele   NVARCHAR(10) NOT NULL,
    Essai    INT          NOT NULL,
    DureeMs  DECIMAL(12,3) NOT NULL
);

/* ---------------------------------------------------------------------
   1. Les six requêtes mesurées (même logique que 05_requetes.sql)
   --------------------------------------------------------------------- */
INSERT INTO #Requetes (Requete, Modele, Texte) VALUES
(N'R1', N'TDW', N'
SELECT ps.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS CA
INTO   #res
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= d.FullDateAlternateKey
       AND d.FullDateAlternateKey < ps.ToDate
GROUP BY ps.ProductSubcategoryKey, d.CalendarYear;
DROP TABLE #res;'),

(N'R1', N'SCD 2', N'
SELECT p.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS CA
INTO   #res
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d         ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
WHERE  p.ProductSubcategoryKey IS NOT NULL
GROUP BY p.ProductSubcategoryKey, d.CalendarYear;
DROP TABLE #res;'),

(N'R2', N'TDW', N'
SELECT ps.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS CA
INTO   #res
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.ToDate = ''9999-12-31''
GROUP BY ps.ProductSubcategoryKey, d.CalendarYear;
DROP TABLE #res;'),

(N'R2', N'SCD 2', N'
WITH VersionCourante AS (
    SELECT ProductAlternateKey, ProductSubcategoryKey,
           ROW_NUMBER() OVER (PARTITION BY ProductAlternateKey
                              ORDER BY CASE WHEN EndDate IS NULL THEN 0 ELSE 1 END,
                                       StartDate DESC, ProductKey DESC) AS rn
    FROM   tdw_scd2.DimProduit)
SELECT c.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS CA
INTO   #res
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d         ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
JOIN   VersionCourante AS c     ON c.ProductAlternateKey = p.ProductAlternateKey AND c.rn = 1
WHERE  c.ProductSubcategoryKey IS NOT NULL
GROUP BY c.ProductSubcategoryKey, d.CalendarYear;
DROP TABLE #res;'),

(N'R3', N'TDW', N'
SELECT ps.ProductSubcategoryKey, AVG(v.SalesAmount) AS Moyenne
INTO   #res
FROM   tdw.Ventes AS v
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= @veille
       AND @veille < ps.ToDate
GROUP BY ps.ProductSubcategoryKey;
DROP TABLE #res;'),

(N'R3', N'SCD 2', N'
WITH VersionALaDate AS (
    SELECT ProductAlternateKey, ProductSubcategoryKey,
           ROW_NUMBER() OVER (
               PARTITION BY ProductAlternateKey
               ORDER BY CASE WHEN CAST(StartDate AS DATE) <= @veille
                              AND (EndDate IS NULL OR @veille <= CAST(EndDate AS DATE))
                             THEN 0 ELSE 1 END,
                        CASE WHEN CAST(StartDate AS DATE) <= @veille
                              AND (EndDate IS NULL OR @veille <= CAST(EndDate AS DATE))
                             THEN StartDate END DESC,
                        StartDate ASC, ProductKey ASC) AS rn
    FROM   tdw_scd2.DimProduit)
SELECT a.ProductSubcategoryKey, AVG(v.SalesAmount) AS Moyenne
INTO   #res
FROM   tdw_scd2.Ventes AS v
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
JOIN   VersionALaDate AS a      ON a.ProductAlternateKey = p.ProductAlternateKey AND a.rn = 1
WHERE  a.ProductSubcategoryKey IS NOT NULL
GROUP BY a.ProductSubcategoryKey;
DROP TABLE #res;');
GO

/* ---------------------------------------------------------------------
   2. Procédure de mesure (exécutée pour chaque phase)
      Essai 0 = chauffe, non retenu ; essais 1 à 3 = mesurés.
   --------------------------------------------------------------------- */
DECLARE @phase NVARCHAR(15) = N'1-sans index';
DECLARE @t1 DATE = (SELECT MIN(DateEffet) FROM tdw.ScenarioJournal WHERE NumEvenement = 1);
DECLARE @veille DATE = DATEADD(DAY, -1, @t1);
DECLARE @id INT, @req NVARCHAR(5), @mod NVARCHAR(10), @sql NVARCHAR(MAX),
        @essai INT, @debut DATETIME2(7);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Id, Requete, Modele, Texte FROM #Requetes ORDER BY Id;
OPEN c;
FETCH NEXT FROM c INTO @id, @req, @mod, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @essai = 0;
    WHILE @essai <= 3
    BEGIN
        IF @essai > 0 SET STATISTICS TIME ON;
        SET @debut = SYSDATETIME();
        EXEC sp_executesql @sql, N'@veille DATE', @veille = @veille;
        IF @essai > 0
        BEGIN
            INSERT INTO #Mesures (Phase, Requete, Modele, Essai, DureeMs)
            VALUES (@phase, @req, @mod, @essai,
                    DATEDIFF_BIG(MICROSECOND, @debut, SYSDATETIME()) / 1000.0);
            SET STATISTICS TIME OFF;
        END;
        SET @essai += 1;
    END;
    FETCH NEXT FROM c INTO @id, @req, @mod, @sql;
END;
CLOSE c; DEALLOCATE c;
GO

/* ---------------------------------------------------------------------
   3. Création des index (clé du membre, FromDate, ToDate)
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IX_ProduitSousCategorie_Intervalle
    ON tdw.ProduitSousCategorie (ProduitKey, FromDate, ToDate) INCLUDE (ProductSubcategoryKey);
CREATE NONCLUSTERED INDEX IX_ProduitPrix_Intervalle
    ON tdw.ProduitPrix (ProduitKey, FromDate, ToDate) INCLUDE (PrixCatalogue);
CREATE NONCLUSTERED INDEX IX_ProduitDureeVie_Intervalle
    ON tdw.ProduitDureeVie (ProduitKey, FromDate, ToDate);
CREATE NONCLUSTERED INDEX IX_SousCategorieNom_Intervalle
    ON tdw.SousCategorieNom (ProductSubcategoryKey, FromDate, ToDate) INCLUDE (NomSousCategorie);
CREATE NONCLUSTERED INDEX IX_EmployeSupervision_Intervalle
    ON tdw.EmployeSupervision (EmployeKey, FromDate, ToDate) INCLUDE (SuperviseurKey);
CREATE NONCLUSTERED INDEX IX_EmployeTerritoire_Intervalle
    ON tdw.EmployeTerritoire (EmployeKey, FromDate, ToDate) INCLUDE (SalesTerritoryKey);
CREATE NONCLUSTERED INDEX IX_scd2_DimProduit_Intervalle
    ON tdw_scd2.DimProduit (ProductAlternateKey, StartDate, EndDate) INCLUDE (ProductSubcategoryKey);
GO

/* ---------------------------------------------------------------------
   4. Même mesure, phase 2 (avec index)
   --------------------------------------------------------------------- */
DECLARE @phase NVARCHAR(15) = N'2-avec index';
DECLARE @t1 DATE = (SELECT MIN(DateEffet) FROM tdw.ScenarioJournal WHERE NumEvenement = 1);
DECLARE @veille DATE = DATEADD(DAY, -1, @t1);
DECLARE @id INT, @req NVARCHAR(5), @mod NVARCHAR(10), @sql NVARCHAR(MAX),
        @essai INT, @debut DATETIME2(7);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Id, Requete, Modele, Texte FROM #Requetes ORDER BY Id;
OPEN c;
FETCH NEXT FROM c INTO @id, @req, @mod, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @essai = 0;
    WHILE @essai <= 3
    BEGIN
        IF @essai > 0 SET STATISTICS TIME ON;
        SET @debut = SYSDATETIME();
        EXEC sp_executesql @sql, N'@veille DATE', @veille = @veille;
        IF @essai > 0
        BEGIN
            INSERT INTO #Mesures (Phase, Requete, Modele, Essai, DureeMs)
            VALUES (@phase, @req, @mod, @essai,
                    DATEDIFF_BIG(MICROSECOND, @debut, SYSDATETIME()) / 1000.0);
            SET STATISTICS TIME OFF;
        END;
        SET @essai += 1;
    END;
    FETCH NEXT FROM c INTO @id, @req, @mod, @sql;
END;
CLOSE c; DEALLOCATE c;
GO

/* ---------------------------------------------------------------------
   5. Résultats
   --------------------------------------------------------------------- */

/* 5a. Détail des 3 essais */
SELECT Phase, Requete, Modele, Essai, DureeMs
FROM   #Mesures
ORDER BY Phase, Requete, Modele, Essai;

/* 5b. Médiane par requête, modèle et phase (tableau pour le rapport) */
WITH Medianes AS (
    SELECT DISTINCT Phase, Requete, Modele,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DureeMs)
               OVER (PARTITION BY Phase, Requete, Modele) AS MedianeMs
    FROM   #Mesures
)
SELECT Requete, Modele,
       CAST(MAX(CASE WHEN Phase = N'1-sans index' THEN MedianeMs END) AS DECIMAL(12,1)) AS MedianeSansIndexMs,
       CAST(MAX(CASE WHEN Phase = N'2-avec index' THEN MedianeMs END) AS DECIMAL(12,1)) AS MedianeAvecIndexMs
FROM   Medianes
GROUP BY Requete, Modele
ORDER BY Requete, Modele DESC;

DROP TABLE #Mesures;
DROP TABLE #Requetes;
GO
