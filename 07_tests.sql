/* =====================================================================
   07_tests.sql  —  Étape F1 : tests de validation

   À exécuter après 02 → 03 → 04 (indépendant de 05 et 06).

   Une requête par test. Chaque test renvoie ZÉRO LIGNE (aucune anomalie)
   ou une ÉGALITÉ VÉRIFIÉE (test 1). Le résultat attendu est indiqué
   au-dessus de chaque requête.

   Après chaque test, le nombre de lignes renvoyées est noté
   (@@ROWCOUNT) ; un tableau récapitulatif OK / ÉCHEC est affiché à la fin.
   ===================================================================== */

SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#Resultats') IS NOT NULL DROP TABLE #Resultats;
CREATE TABLE #Resultats (
    Test      NVARCHAR(10)  NOT NULL,
    Libelle   NVARCHAR(200) NOT NULL,
    Anomalies INT           NOT NULL,
    Resultat  AS (CASE WHEN Anomalies = 0 THEN N'OK' ELSE N'ÉCHEC' END)
);
GO

/* =====================================================================
   Test 1 — tdw.Ventes a le même nombre de lignes et la même somme de
   SalesAmount que dbo.FactResellerSales.
   Attendu : 1 ligne, Resultat = OK (égalité vérifiée).
   ===================================================================== */
SELECT N'Test 1' AS Test,
       s.NbLignes AS NbLignesSource, t.NbLignes AS NbLignesTdw,
       s.Somme    AS SommeSource,    t.Somme    AS SommeTdw,
       CASE WHEN s.NbLignes = t.NbLignes AND s.Somme = t.Somme
            THEN N'OK' ELSE N'ÉCHEC' END AS Resultat
FROM      (SELECT COUNT(*) AS NbLignes, SUM(SalesAmount) AS Somme FROM dbo.FactResellerSales) AS s
CROSS JOIN (SELECT COUNT(*) AS NbLignes, SUM(SalesAmount) AS Somme FROM tdw.Ventes)          AS t;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
SELECT N'1', N'tdw.Ventes = dbo.FactResellerSales (lignes et somme)',
       CASE WHEN (SELECT COUNT(*) FROM dbo.FactResellerSales) = (SELECT COUNT(*) FROM tdw.Ventes)
             AND (SELECT SUM(SalesAmount) FROM dbo.FactResellerSales) = (SELECT SUM(SalesAmount) FROM tdw.Ventes)
            THEN 0 ELSE 1 END;
GO

/* =====================================================================
   Test 2 — Aucune table temporelle ne contient deux intervalles qui se
   chevauchent pour un même membre.
   [a.From, a.To) et [b.From, b.To) se chevauchent ssi l'un commence
   avant la fin de l'autre ; FromDate étant unique par membre (clé
   primaire), on teste a.FromDate < b.FromDate < a.ToDate.
   Attendu : 0 ligne.
   ===================================================================== */
DECLARE @n INT;

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
FROM   Intervalles AS a
JOIN   Intervalles AS b
       ON  b.TableTemporelle = a.TableTemporelle
       AND b.Membre = a.Membre
       AND a.FromDate < b.FromDate
       AND b.FromDate < a.ToDate;
SET @n = @@ROWCOUNT;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'2', N'Aucun chevauchement d''intervalles dans les 6 tables temporelles', @n);
GO

/* =====================================================================
   Test 3 — Contrainte de synchronisation (p. 128) : chaque vente tombe
   dans la durée de vie de son produit, et le produit a une
   sous-catégorie valide à la date de la vente.
   Attendu : 0 ligne.
   ===================================================================== */
DECLARE @n INT;

SELECT v.SalesOrderNumber, v.SalesOrderLineNumber, v.ProduitKey,
       d.FullDateAlternateKey AS DateVente,
       CASE WHEN NOT EXISTS (SELECT 1 FROM tdw.ProduitDureeVie AS l
                             WHERE  l.ProduitKey = v.ProduitKey
                               AND  l.FromDate <= d.FullDateAlternateKey
                               AND  d.FullDateAlternateKey < l.ToDate)
            THEN N'hors durée de vie' ELSE N'sans sous-catégorie valide' END AS Anomalie
FROM   tdw.Ventes  AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
WHERE  NOT EXISTS (SELECT 1 FROM tdw.ProduitDureeVie AS l
                   WHERE  l.ProduitKey = v.ProduitKey
                     AND  l.FromDate <= d.FullDateAlternateKey
                     AND  d.FullDateAlternateKey < l.ToDate)
   OR  NOT EXISTS (SELECT 1 FROM tdw.ProduitSousCategorie AS ps
                   WHERE  ps.ProduitKey = v.ProduitKey
                     AND  ps.FromDate <= d.FullDateAlternateKey
                     AND  d.FullDateAlternateKey < ps.ToDate);
SET @n = @@ROWCOUNT;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'3', N'Synchronisation : vente dans la durée de vie, sous-catégorie valide à la date', @n);
GO

/* =====================================================================
   Test 4 — Pour chaque année, la somme des lignes de R1 (TDW) est égale
   au chiffre d'affaires total de l'année. Un oubli de la condition
   temporelle compterait certaines ventes deux fois ; une vente sans
   sous-catégorie valide disparaîtrait.
   Attendu : 0 ligne (aucune année en écart).
   ===================================================================== */
DECLARE @n INT;

WITH R1 AS (
    SELECT ps.ProductSubcategoryKey, d.CalendarYear AS Annee, SUM(v.SalesAmount) AS ChiffreAffaires
    FROM   tdw.Ventes AS v
    JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
    JOIN   tdw.ProduitSousCategorie AS ps
           ON  ps.ProduitKey = v.ProduitKey
           AND ps.FromDate <= d.FullDateAlternateKey
           AND d.FullDateAlternateKey < ps.ToDate
    GROUP BY ps.ProductSubcategoryKey, d.CalendarYear
),
SommeR1 AS (
    SELECT Annee, SUM(ChiffreAffaires) AS SommeR1 FROM R1 GROUP BY Annee
),
CAAnnee AS (
    SELECT d.CalendarYear AS Annee, SUM(f.SalesAmount) AS CAAnnee
    FROM   dbo.FactResellerSales AS f
    JOIN   dbo.DimDate AS d ON d.DateKey = f.OrderDateKey
    GROUP BY d.CalendarYear
)
SELECT COALESCE(c.Annee, r.Annee) AS Annee, c.CAAnnee, r.SommeR1,
       ISNULL(c.CAAnnee, 0) - ISNULL(r.SommeR1, 0) AS Ecart
FROM   CAAnnee AS c
FULL OUTER JOIN SommeR1 AS r ON r.Annee = c.Annee
WHERE  ISNULL(c.CAAnnee, 0) <> ISNULL(r.SommeR1, 0);
SET @n = @@ROWCOUNT;

INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'4', N'Somme annuelle de R1 = chiffre d''affaires total de l''année', @n);
GO

/* =====================================================================
   Préparation du test 5 (pas un test) : R1, R2, R3 matérialisées dans
   les deux modèles, avec la même logique que 05_requetes.sql (sans les
   colonnes d'affichage).
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
   Test 5 — R1, R2 et R3 donnent exactement le même résultat dans les
   deux modèles, vérifié dans les deux sens avec EXCEPT.
   Attendu : 0 ligne pour chacune des requêtes 5a, 5b, 5c.
   ===================================================================== */

/* Test 5a — R1. Attendu : 0 ligne. */
DECLARE @n INT;
SELECT N'TDW sans SCD 2' AS Sens, * FROM (SELECT * FROM #R1_tdw  EXCEPT SELECT * FROM #R1_scd2) AS a
UNION ALL
SELECT N'SCD 2 sans TDW',         * FROM (SELECT * FROM #R1_scd2 EXCEPT SELECT * FROM #R1_tdw)  AS b;
SET @n = @@ROWCOUNT;
INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'5a', N'R1 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', @n);

/* Test 5b — R2. Attendu : 0 ligne. */
SELECT N'TDW sans SCD 2' AS Sens, * FROM (SELECT * FROM #R2_tdw  EXCEPT SELECT * FROM #R2_scd2) AS a
UNION ALL
SELECT N'SCD 2 sans TDW',         * FROM (SELECT * FROM #R2_scd2 EXCEPT SELECT * FROM #R2_tdw)  AS b;
SET @n = @@ROWCOUNT;
INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'5b', N'R2 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', @n);

/* Test 5c — R3. Attendu : 0 ligne. */
SELECT N'TDW sans SCD 2' AS Sens, * FROM (SELECT * FROM #R3_tdw  EXCEPT SELECT * FROM #R3_scd2) AS a
UNION ALL
SELECT N'SCD 2 sans TDW',         * FROM (SELECT * FROM #R3_scd2 EXCEPT SELECT * FROM #R3_tdw)  AS b;
SET @n = @@ROWCOUNT;
INSERT INTO #Resultats (Test, Libelle, Anomalies)
VALUES (N'5c', N'R3 identique dans TDW et SCD 2 (EXCEPT dans les deux sens)', @n);
GO

/* =====================================================================
   Contrôle de sens (pas un test de la consigne) : R1 et R2 doivent
   DIFFÉRER, sinon le scénario n'a rien changé.
   Attendu : 4 lignes différentes (Jerseys 2010, 2011, 2012 ; Vests 2012).
   ===================================================================== */
SELECT N'Contrôle' AS Test, COUNT(*) AS LignesDifferentesR1R2
FROM  (SELECT * FROM #R1_tdw EXCEPT SELECT * FROM #R2_tdw) AS x;

DROP TABLE #R1_tdw; DROP TABLE #R1_scd2; DROP TABLE #R2_tdw;
DROP TABLE #R2_scd2; DROP TABLE #R3_tdw; DROP TABLE #R3_scd2;
GO

/* =====================================================================
   Récapitulatif
   ===================================================================== */
SELECT Test, Resultat, Anomalies, Libelle FROM #Resultats ORDER BY Test;
DROP TABLE #Resultats;
GO
