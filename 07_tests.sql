/* =====================================================================
   07_tests.sql  —  Étape F1 : tests de validation

   À exécuter après 02 → 03 → 04 (et indépendamment de 05).
   Chaque test renvoie zéro ligne d'anomalie, ou vérifie une égalité.
   Un tableau récapitulatif final indique OK / ÉCHEC pour chaque test ;
   en cas d'échec, les lignes fautives sont affichées juste avant.
   ===================================================================== */

SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#Resultats') IS NOT NULL DROP TABLE #Resultats;
CREATE TABLE #Resultats (
    Test     NVARCHAR(10)  NOT NULL,
    Libelle  NVARCHAR(200) NOT NULL,
    Anomalies INT          NOT NULL,
    Resultat AS (CASE WHEN Anomalies = 0 THEN N'OK' ELSE N'ÉCHEC' END)
);
GO

/* =====================================================================
   Test 1 — tdw.Ventes a le même nombre de lignes et la même somme de
   SalesAmount que dbo.FactResellerSales.
   ===================================================================== */
DECLARE @nSrc INT, @nTdw INT, @sSrc MONEY, @sTdw MONEY;
SELECT @nSrc = COUNT(*), @sSrc = SUM(SalesAmount) FROM dbo.FactResellerSales;
SELECT @nTdw = COUNT(*), @sTdw = SUM(SalesAmount) FROM tdw.Ventes;

SELECT N'Test 1' AS Test, @nSrc AS NbLignesSource, @nTdw AS NbLignesTdw,
       @sSrc AS SommeSource, @sTdw AS SommeTdw;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'1', N'tdw.Ventes = dbo.FactResellerSales (lignes et somme)',
        CASE WHEN @nSrc = @nTdw AND @sSrc = @sTdw THEN 0 ELSE 1 END);
GO

/* =====================================================================
   Test 2 — Aucune table temporelle ne contient deux intervalles qui se
   chevauchent pour un même membre.
   Deux intervalles [a.From, a.To) et [b.From, b.To) d'un même membre se
   chevauchent ssi a.From < b.To ET b.From < a.To (a et b distincts).
   ===================================================================== */
WITH Intervalles AS (
    SELECT N'ProduitDureeVie'      AS TableTemporelle, ProduitKey            AS Membre, FromDate, ToDate FROM tdw.ProduitDureeVie
    UNION ALL
    SELECT N'ProduitPrix',          ProduitKey,            FromDate, ToDate FROM tdw.ProduitPrix
    UNION ALL
    SELECT N'ProduitSousCategorie', ProduitKey,            FromDate, ToDate FROM tdw.ProduitSousCategorie
    UNION ALL
    SELECT N'SousCategorieNom',     ProductSubcategoryKey, FromDate, ToDate FROM tdw.SousCategorieNom
    UNION ALL
    SELECT N'EmployeSupervision',   EmployeKey,            FromDate, ToDate FROM tdw.EmployeSupervision
    UNION ALL
    SELECT N'EmployeTerritoire',    EmployeKey,            FromDate, ToDate FROM tdw.EmployeTerritoire
)
SELECT a.TableTemporelle, a.Membre,
       a.FromDate AS FromA, a.ToDate AS ToA,
       b.FromDate AS FromB, b.ToDate AS ToB
INTO   #Chevauchements
FROM   Intervalles AS a
JOIN   Intervalles AS b
       ON  b.TableTemporelle = a.TableTemporelle
       AND b.Membre = a.Membre
       AND a.FromDate < b.FromDate          -- chaque paire une seule fois (FromDate unique par membre : PK)
       AND b.FromDate < a.ToDate;           -- b commence avant la fin de a → chevauchement

IF EXISTS (SELECT 1 FROM #Chevauchements)
    SELECT N'Test 2 — chevauchements' AS Test, * FROM #Chevauchements;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'2', N'Aucun chevauchement d''intervalles dans les 6 tables temporelles', COUNT(*)
FROM   #Chevauchements;

DROP TABLE #Chevauchements;
GO

/* =====================================================================
   Test 3 — Contrainte de synchronisation (p. 128) : chaque vente tombe
   dans la durée de vie de son produit, et le produit a une
   sous-catégorie valide à la date de la vente.
   ===================================================================== */
SELECT v.SalesOrderNumber, v.SalesOrderLineNumber, v.ProduitKey,
       d.FullDateAlternateKey AS DateVente,
       CASE WHEN NOT EXISTS (SELECT 1 FROM tdw.ProduitDureeVie AS l
                             WHERE  l.ProduitKey = v.ProduitKey
                               AND  l.FromDate <= d.FullDateAlternateKey
                               AND  d.FullDateAlternateKey < l.ToDate)
            THEN 1 ELSE 0 END AS HorsDureeVie,
       CASE WHEN NOT EXISTS (SELECT 1 FROM tdw.ProduitSousCategorie AS ps
                             WHERE  ps.ProduitKey = v.ProduitKey
                               AND  ps.FromDate <= d.FullDateAlternateKey
                               AND  d.FullDateAlternateKey < ps.ToDate)
            THEN 1 ELSE 0 END AS SansSousCategorie
INTO   #Synchro
FROM   tdw.Ventes  AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey;

DELETE FROM #Synchro WHERE HorsDureeVie = 0 AND SansSousCategorie = 0;

IF EXISTS (SELECT 1 FROM #Synchro)
    SELECT TOP (50) N'Test 3 — ventes non synchronisées' AS Test, * FROM #Synchro;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'3', N'Synchronisation : vente dans la durée de vie, sous-catégorie valide à la date', COUNT(*)
FROM   #Synchro;

DROP TABLE #Synchro;
GO

/* =====================================================================
   Requêtes R1, R2, R3 matérialisées pour les tests 4 et 5
   (même logique que 05_requetes.sql, sans les colonnes d'affichage)
   ===================================================================== */
IF OBJECT_ID('tempdb..#R1_tdw')  IS NOT NULL DROP TABLE #R1_tdw;
IF OBJECT_ID('tempdb..#R1_scd2') IS NOT NULL DROP TABLE #R1_scd2;
IF OBJECT_ID('tempdb..#R2_tdw')  IS NOT NULL DROP TABLE #R2_tdw;
IF OBJECT_ID('tempdb..#R2_scd2') IS NOT NULL DROP TABLE #R2_scd2;
IF OBJECT_ID('tempdb..#R3_tdw')  IS NOT NULL DROP TABLE #R3_tdw;
IF OBJECT_ID('tempdb..#R3_scd2') IS NOT NULL DROP TABLE #R3_scd2;

/* R1 — TDW */
SELECT ps.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS ChiffreAffaires
INTO   #R1_tdw
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= d.FullDateAlternateKey
       AND d.FullDateAlternateKey < ps.ToDate
GROUP BY ps.ProductSubcategoryKey, d.CalendarYear;

/* R1 — SCD 2 */
SELECT p.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS ChiffreAffaires
INTO   #R1_scd2
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d         ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
WHERE  p.ProductSubcategoryKey IS NOT NULL
GROUP BY p.ProductSubcategoryKey, d.CalendarYear;

/* R2 — TDW */
SELECT ps.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS ChiffreAffaires
INTO   #R2_tdw
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.ToDate = '9999-12-31'
GROUP BY ps.ProductSubcategoryKey, d.CalendarYear;

/* R2 — SCD 2 */
WITH VersionCourante AS (
    SELECT ProductAlternateKey, ProductSubcategoryKey,
           ROW_NUMBER() OVER (PARTITION BY ProductAlternateKey
                              ORDER BY CASE WHEN EndDate IS NULL THEN 0 ELSE 1 END,
                                       StartDate DESC, ProductKey DESC) AS rn
    FROM   tdw_scd2.DimProduit
)
SELECT c.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS ChiffreAffaires
INTO   #R2_scd2
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d         ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
JOIN   VersionCourante AS c     ON c.ProductAlternateKey = p.ProductAlternateKey AND c.rn = 1
WHERE  c.ProductSubcategoryKey IS NOT NULL
GROUP BY c.ProductSubcategoryKey, d.CalendarYear;

/* R3 — TDW et SCD 2 (veille de @t1) */
DECLARE @t1     DATE = (SELECT MIN(DateEffet) FROM tdw.ScenarioJournal WHERE NumEvenement = 1);
DECLARE @veille DATE = DATEADD(DAY, -1, @t1);

SELECT ps.ProductSubcategoryKey, AVG(v.SalesAmount) AS MontantMoyenLigne, COUNT(*) AS NbLignes
INTO   #R3_tdw
FROM   tdw.Ventes AS v
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= @veille
       AND @veille < ps.ToDate
GROUP BY ps.ProductSubcategoryKey;

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
                        StartDate ASC,
                        ProductKey ASC) AS rn
    FROM   tdw_scd2.DimProduit
)
SELECT a.ProductSubcategoryKey, AVG(v.SalesAmount) AS MontantMoyenLigne, COUNT(*) AS NbLignes
INTO   #R3_scd2
FROM   tdw_scd2.Ventes AS v
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
JOIN   VersionALaDate AS a      ON a.ProductAlternateKey = p.ProductAlternateKey AND a.rn = 1
WHERE  a.ProductSubcategoryKey IS NOT NULL
GROUP BY a.ProductSubcategoryKey;
GO

/* =====================================================================
   Test 4 — Pour chaque année, la somme des lignes de R1 (TDW) est égale
   au chiffre d'affaires total de l'année. Un oubli de la condition
   temporelle compterait certaines ventes deux fois ; une vente sans
   sous-catégorie valide disparaîtrait.
   ===================================================================== */
WITH TotalR1 AS (
    SELECT Annee, SUM(ChiffreAffaires) AS SommeR1 FROM #R1_tdw GROUP BY Annee
),
TotalAnnee AS (
    SELECT d.CalendarYear AS Annee, SUM(f.SalesAmount) AS CAAnnee
    FROM   dbo.FactResellerSales AS f
    JOIN   dbo.DimDate AS d ON d.DateKey = f.OrderDateKey
    GROUP BY d.CalendarYear
)
SELECT t.Annee, t.CAAnnee, r.SommeR1,
       t.CAAnnee - ISNULL(r.SommeR1, 0) AS Ecart
INTO   #Test4
FROM   TotalAnnee AS t
LEFT JOIN TotalR1 AS r ON r.Annee = t.Annee;

SELECT N'Test 4' AS Test, * FROM #Test4 ORDER BY Annee;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'4', N'Somme annuelle de R1 = chiffre d''affaires total de l''année', COUNT(*)
FROM   #Test4 WHERE Ecart <> 0;

DROP TABLE #Test4;
GO

/* =====================================================================
   Test 5 — R1, R2 et R3 donnent exactement le même résultat dans les
   deux modèles. Vérifié dans les deux sens avec EXCEPT :
   (TDW EXCEPT SCD2) et (SCD2 EXCEPT TDW) doivent être vides.
   ===================================================================== */
SELECT N'R1' AS Requete, N'TDW sans SCD2' AS Sens, * INTO #Diff5 FROM (SELECT * FROM #R1_tdw  EXCEPT SELECT * FROM #R1_scd2) AS x;
INSERT INTO #Diff5 SELECT N'R1', N'SCD2 sans TDW', * FROM (SELECT * FROM #R1_scd2 EXCEPT SELECT * FROM #R1_tdw)  AS x;
INSERT INTO #Diff5 SELECT N'R2', N'TDW sans SCD2', * FROM (SELECT * FROM #R2_tdw  EXCEPT SELECT * FROM #R2_scd2) AS x;
INSERT INTO #Diff5 SELECT N'R2', N'SCD2 sans TDW', * FROM (SELECT * FROM #R2_scd2 EXCEPT SELECT * FROM #R2_tdw)  AS x;

SELECT N'R3' AS Requete, N'TDW sans SCD2' AS Sens, * INTO #Diff5R3 FROM (SELECT * FROM #R3_tdw  EXCEPT SELECT * FROM #R3_scd2) AS x;
INSERT INTO #Diff5R3 SELECT N'R3', N'SCD2 sans TDW', * FROM (SELECT * FROM #R3_scd2 EXCEPT SELECT * FROM #R3_tdw)  AS x;

IF EXISTS (SELECT 1 FROM #Diff5)   SELECT N'Test 5 — écarts R1/R2' AS Test, * FROM #Diff5;
IF EXISTS (SELECT 1 FROM #Diff5R3) SELECT N'Test 5 — écarts R3'    AS Test, * FROM #Diff5R3;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'5-R1', N'R1 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', COUNT(*) FROM #Diff5 WHERE Requete = N'R1';
INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'5-R2', N'R2 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', COUNT(*) FROM #Diff5 WHERE Requete = N'R2';
INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'5-R3', N'R3 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', COUNT(*) FROM #Diff5R3;

/* Contrôle de sens : R1 et R2 doivent DIFFÉRER (sinon le scénario n'a rien changé) */
SELECT N'Contrôle' AS Test, COUNT(*) AS LignesDifferentesR1R2
FROM  (SELECT * FROM #R1_tdw EXCEPT SELECT * FROM #R2_tdw) AS x;

DROP TABLE #Diff5; DROP TABLE #Diff5R3;
DROP TABLE #R1_tdw; DROP TABLE #R1_scd2; DROP TABLE #R2_tdw;
DROP TABLE #R2_scd2; DROP TABLE #R3_tdw; DROP TABLE #R3_scd2;
GO

/* =====================================================================
   Récapitulatif
   ===================================================================== */
SELECT Test, Resultat, Anomalies, Libelle FROM #Resultats ORDER BY Test;
DROP TABLE #Resultats;
GO
