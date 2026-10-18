/* =====================================================================
   04_scenario.sql  —  Scénario de changements (fourni par l'enseignant)
   Devoir : entrepôt de données temporel sur AdventureWorksDW
   Article : Ahmed, Zimányi, Vaisman, Wrembel (2020), IJDWM 16(4)

   NE PAS MODIFIER CE SCRIPT.

   Prérequis : les schémas tdw et tdw_scd2 sont créés et chargés
   en respectant exactement les noms et les règles de l'étape C.

   Le script :
     - s'exécute en une seule transaction (tout ou rien) ;
     - refuse de s'exécuter une deuxième fois ;
     - applique quatre événements datés à @t1, @t2, @t3 et @t4 ;
     - affiche à la fin son journal (tdw.ScenarioJournal).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'tdw.ScenarioJournal', N'U') IS NOT NULL
    THROW 50000, N'Le scénario a déjà été exécuté. Rechargez vos tables (scripts 02 et 03) avant de le rejouer.', 1;

BEGIN TRANSACTION;

CREATE TABLE tdw.ScenarioJournal (
    NumEvenement   INT           NOT NULL,
    Evenement      NVARCHAR(40)  NOT NULL,
    Objet          NVARCHAR(100) NOT NULL,
    DateEffet      DATE          NOT NULL,
    AncienneValeur NVARCHAR(100) NULL,
    NouvelleValeur NVARCHAR(100) NULL
);

/* ---------------------------------------------------------------------
   Dates des événements : 40 %, 50 %, 55 % et 60 % de la période des
   ventes, arrondies au premier jour du mois.
   --------------------------------------------------------------------- */
DECLARE @debut DATE, @fin DATE;

SELECT @debut = MIN(d.FullDateAlternateKey),
       @fin   = MAX(d.FullDateAlternateKey)
FROM   dbo.FactResellerSales AS f
JOIN   dbo.DimDate AS d ON d.DateKey = f.OrderDateKey;

DECLARE @n  INT  = DATEDIFF(DAY, @debut, @fin);
DECLARE @t1 DATE = DATEADD(DAY, @n * 40 / 100, @debut);
DECLARE @t2 DATE = DATEADD(DAY, @n * 50 / 100, @debut);
DECLARE @t3 DATE = DATEADD(DAY, @n * 55 / 100, @debut);
DECLARE @t4 DATE = DATEADD(DAY, @n * 60 / 100, @debut);

SET @t1 = DATEFROMPARTS(YEAR(@t1), MONTH(@t1), 1);
SET @t2 = DATEFROMPARTS(YEAR(@t2), MONTH(@t2), 1);
SET @t3 = DATEFROMPARTS(YEAR(@t3), MONTH(@t3), 1);
SET @t4 = DATEFROMPARTS(YEAR(@t4), MONTH(@t4), 1);

/* Sous-catégories utilisées par le scénario */
DECLARE @scJerseys INT = (SELECT ProductSubcategoryKey FROM dbo.DimProductSubcategory
                          WHERE EnglishProductSubcategoryName = N'Jerseys');
DECLARE @scVests   INT = (SELECT ProductSubcategoryKey FROM dbo.DimProductSubcategory
                          WHERE EnglishProductSubcategoryName = N'Vests');

IF @scJerseys IS NULL OR @scVests IS NULL
    THROW 50001, N'Sous-catégories Jerseys ou Vests introuvables dans dbo.DimProductSubcategory.', 1;

DECLARE @nb INT;

/* =====================================================================
   ÉVÉNEMENT 1 (@t1) : 3 produits passent de Jerseys à Vests
   Modèle TDW : tdw.ProduitSousCategorie
   Modèle SCD 2 : tdw_scd2.DimProduit et tdw_scd2.Ventes
   ===================================================================== */

/* Les 3 produits Jerseys au plus fort CA, vendus avant ET après @t1 */
DECLARE @produits TABLE (ProduitKey INT PRIMARY KEY);

INSERT INTO @produits (ProduitKey)
SELECT TOP (3) v.ProduitKey
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.ProductSubcategoryKey = @scJerseys
       AND ps.FromDate <  @t1
       AND @t1 < ps.ToDate
GROUP BY v.ProduitKey
HAVING SUM(CASE WHEN d.FullDateAlternateKey <  @t1 THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN d.FullDateAlternateKey >= @t1 THEN 1 ELSE 0 END) > 0
ORDER BY SUM(v.SalesAmount) DESC;

IF (SELECT COUNT(*) FROM @produits) <> 3
    THROW 50002, N'Événement 1 : moins de 3 produits Jerseys trouvés. Vérifiez tdw.Ventes et tdw.ProduitSousCategorie (étape C2 : un intervalle [1900-01-01, 9999-12-31) par produit).', 1;

/* --- 1a. Modèle TDW : clôturer l'intervalle, puis ouvrir le nouveau --- */
DECLARE @fermes TABLE (ProduitKey INT, AncienneFin DATE);

UPDATE ps
SET    ps.ToDate = @t1
OUTPUT deleted.ProduitKey, deleted.ToDate INTO @fermes (ProduitKey, AncienneFin)
FROM   tdw.ProduitSousCategorie AS ps
JOIN   @produits AS p ON p.ProduitKey = ps.ProduitKey
WHERE  ps.ProductSubcategoryKey = @scJerseys
  AND  ps.FromDate < @t1
  AND  @t1 < ps.ToDate;

INSERT INTO tdw.ProduitSousCategorie (ProduitKey, ProductSubcategoryKey, FromDate, ToDate)
SELECT ProduitKey, @scVests, @t1, AncienneFin
FROM   @fermes;

INSERT INTO tdw.ScenarioJournal (NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur)
SELECT 1, N'Changement de sous-catégorie',
       CONCAT(pr.ProductAlternateKey, N' – ', pr.NomProduit), @t1, N'Jerseys', N'Vests'
FROM   @produits AS p
JOIN   tdw.Produit AS pr ON pr.ProduitKey = p.ProduitKey;

/* --- 1b. Modèle SCD 2 : nouvelle version, clôture, réaffectation des faits --- */
DECLARE @versions TABLE (ProductAlternateKey NVARCHAR(25), NouvelleCle INT);

WITH courante AS (
    SELECT dp.*,
           ROW_NUMBER() OVER (PARTITION BY dp.ProductAlternateKey
                              ORDER BY CASE WHEN dp.EndDate IS NULL THEN 0 ELSE 1 END,
                                       dp.StartDate DESC, dp.ProductKey DESC) AS rn
    FROM   tdw_scd2.DimProduit AS dp
    JOIN   tdw.Produit AS pr ON pr.ProductAlternateKey = dp.ProductAlternateKey
    JOIN   @produits   AS p  ON p.ProduitKey = pr.ProduitKey
)
INSERT INTO tdw_scd2.DimProduit
       (ProductAlternateKey, EnglishProductName, ProductSubcategoryKey,
        ListPrice, StartDate, EndDate, Status)
OUTPUT inserted.ProductAlternateKey, inserted.ProductKey INTO @versions (ProductAlternateKey, NouvelleCle)
SELECT ProductAlternateKey, EnglishProductName, @scVests,
       ListPrice, @t1, NULL, N'Current'
FROM   courante
WHERE  rn = 1;

/* Clôturer l'ancienne version courante (intervalle fermé, comme dans AdventureWorksDW) */
UPDATE dp
SET    dp.EndDate = DATEADD(DAY, -1, @t1),
       dp.Status  = NULL
FROM   tdw_scd2.DimProduit AS dp
JOIN   @versions AS v ON v.ProductAlternateKey = dp.ProductAlternateKey
WHERE  dp.ProductKey <> v.NouvelleCle
  AND  dp.EndDate IS NULL;

/* Les ventes à partir de @t1 pointent vers la nouvelle version */
UPDATE f
SET    f.ProductKey = v.NouvelleCle
FROM   tdw_scd2.Ventes     AS f
JOIN   tdw_scd2.DimProduit AS dp ON dp.ProductKey = f.ProductKey
JOIN   @versions           AS v  ON v.ProductAlternateKey = dp.ProductAlternateKey
JOIN   dbo.DimDate         AS d  ON d.DateKey = f.OrderDateKey
WHERE  d.FullDateAlternateKey >= @t1
  AND  f.ProductKey <> v.NouvelleCle;

SET @nb = @@ROWCOUNT;

INSERT INTO tdw.ScenarioJournal (NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur)
VALUES (1, N'SCD 2 : ventes réaffectées', N'tdw_scd2.Ventes', @t1,
        NULL, CONCAT(@nb, N' lignes de faits modifiées'));

/* =====================================================================
   ÉVÉNEMENT 2 (@t2) : +8 % sur le prix catalogue des produits Bikes
   Modèle TDW uniquement : tdw.ProduitPrix
   ===================================================================== */
DECLARE @prix TABLE (ProduitKey INT, AncienPrix MONEY, AncienneFin DATE);

UPDATE pp
SET    pp.ToDate = @t2
OUTPUT deleted.ProduitKey, deleted.PrixCatalogue, deleted.ToDate
       INTO @prix (ProduitKey, AncienPrix, AncienneFin)
FROM   tdw.ProduitPrix AS pp
WHERE  pp.FromDate < @t2
  AND  @t2 < pp.ToDate
  AND  pp.ProduitKey IN (SELECT ps.ProduitKey
                         FROM   tdw.ProduitSousCategorie AS ps
                         JOIN   dbo.DimProductSubcategory AS sc
                                ON sc.ProductSubcategoryKey = ps.ProductSubcategoryKey
                         JOIN   dbo.DimProductCategory AS c
                                ON c.ProductCategoryKey = sc.ProductCategoryKey
                         WHERE  c.EnglishProductCategoryName = N'Bikes');

IF (SELECT COUNT(*) FROM @prix) = 0
    THROW 50003, N'Événement 2 : aucun prix de produit Bikes à modifier. Vérifiez tdw.ProduitPrix (étape C2).', 1;

INSERT INTO tdw.ProduitPrix (ProduitKey, PrixCatalogue, FromDate, ToDate)
SELECT ProduitKey, ROUND(AncienPrix * 1.08, 2), @t2, AncienneFin
FROM   @prix;

SET @nb = (SELECT COUNT(*) FROM @prix);

INSERT INTO tdw.ScenarioJournal (NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur)
VALUES (2, N'Hausse de prix de 8 %',
        CONCAT(N'Catégorie Bikes (', @nb, N' produits)'),
        @t2, N'prix précédent', N'prix précédent × 1,08');

/* =====================================================================
   ÉVÉNEMENT 3 (@t3) : la sous-catégorie Vests est renommée
   Modèle TDW uniquement : tdw.SousCategorieNom
   ===================================================================== */
DECLARE @noms TABLE (ProductSubcategoryKey INT, AncienNom NVARCHAR(50), AncienneFin DATE);

UPDATE n
SET    n.ToDate = @t3
OUTPUT deleted.ProductSubcategoryKey, deleted.NomSousCategorie, deleted.ToDate
       INTO @noms (ProductSubcategoryKey, AncienNom, AncienneFin)
FROM   tdw.SousCategorieNom AS n
WHERE  n.ProductSubcategoryKey = @scVests
  AND  n.FromDate < @t3
  AND  @t3 < n.ToDate;

IF (SELECT COUNT(*) FROM @noms) <> 1
    THROW 50004, N'Événement 3 : nom de la sous-catégorie Vests introuvable. Vérifiez tdw.SousCategorieNom (étape C2).', 1;

INSERT INTO tdw.SousCategorieNom (ProductSubcategoryKey, NomSousCategorie, FromDate, ToDate)
SELECT ProductSubcategoryKey, N'Vests and Jackets', @t3, AncienneFin
FROM   @noms;

INSERT INTO tdw.ScenarioJournal (NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur)
SELECT 3, N'Renommage de sous-catégorie', CONCAT(N'Sous-catégorie ', ProductSubcategoryKey),
       @t3, AncienNom, N'Vests and Jackets'
FROM   @noms;

/* =====================================================================
   ÉVÉNEMENT 4 (@t4) : le vendeur au plus fort CA change de superviseur
   Modèle TDW uniquement : tdw.EmployeSupervision
   ===================================================================== */
DECLARE @vendeur INT, @ancienSup INT, @nouveauSup INT;

/* Vendeur supervisé à @t4, ayant des ventes avant ET après @t4 */
SELECT TOP (1) @vendeur = s.EmployeKey, @ancienSup = s.SuperviseurKey
FROM   tdw.EmployeSupervision AS s
JOIN   tdw.Ventes  AS v ON v.EmployeKey = s.EmployeKey
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
WHERE  s.FromDate < @t4
  AND  @t4 < s.ToDate
GROUP BY s.EmployeKey, s.SuperviseurKey
HAVING SUM(CASE WHEN d.FullDateAlternateKey <  @t4 THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN d.FullDateAlternateKey >= @t4 THEN 1 ELSE 0 END) > 0
ORDER BY SUM(v.SalesAmount) DESC;

/* Nouveau superviseur : celui qui supervise le plus de vendeurs, autre que l'actuel */
SELECT TOP (1) @nouveauSup = s.SuperviseurKey
FROM   tdw.EmployeSupervision AS s
WHERE  s.SuperviseurKey <> @ancienSup
  AND  s.SuperviseurKey <> @vendeur
  AND  s.FromDate < @t4
  AND  @t4 < s.ToDate
  AND  s.EmployeKey IN (SELECT EmployeKey FROM tdw.Ventes)
GROUP BY s.SuperviseurKey
ORDER BY COUNT(DISTINCT s.EmployeKey) DESC, s.SuperviseurKey;

IF @vendeur IS NULL OR @nouveauSup IS NULL
    THROW 50005, N'Événement 4 : vendeur ou nouveau superviseur introuvable. Vérifiez tdw.EmployeSupervision et tdw.Ventes (étape C).', 1;

DECLARE @sup TABLE (EmployeKey INT, AncienneFin DATE);

UPDATE s
SET    s.ToDate = @t4
OUTPUT deleted.EmployeKey, deleted.ToDate INTO @sup (EmployeKey, AncienneFin)
FROM   tdw.EmployeSupervision AS s
WHERE  s.EmployeKey = @vendeur
  AND  s.SuperviseurKey = @ancienSup
  AND  s.FromDate < @t4
  AND  @t4 < s.ToDate;

INSERT INTO tdw.EmployeSupervision (EmployeKey, SuperviseurKey, FromDate, ToDate)
SELECT EmployeKey, @nouveauSup, @t4, AncienneFin
FROM   @sup;

INSERT INTO tdw.ScenarioJournal (NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur)
SELECT 4, N'Changement de superviseur',
       CONCAT(e.Prenom, N' ', e.Nom), @t4,
       CONCAT(a.Prenom, N' ', a.Nom), CONCAT(n.Prenom, N' ', n.Nom)
FROM   tdw.Employe AS e
JOIN   tdw.Employe AS a ON a.EmployeKey = @ancienSup
JOIN   tdw.Employe AS n ON n.EmployeKey = @nouveauSup
WHERE  e.EmployeKey = @vendeur;

COMMIT TRANSACTION;

/* Journal du scénario : conservez ces dates pour vos requêtes */
SELECT NumEvenement, Evenement, Objet, DateEffet, AncienneValeur, NouvelleValeur
FROM   tdw.ScenarioJournal
ORDER BY NumEvenement, Objet;
