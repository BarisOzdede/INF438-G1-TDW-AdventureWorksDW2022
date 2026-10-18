/* =====================================================================
   03_chargement.sql  —  Étape C : chargement initial (C2, C3, C4)

   À exécuter juste après 02_schema.sql, puis 04_scenario.sql.

   Règles C2 :
   - État initial supposé valide sur toute la période :
     UNE ligne par membre, [1900-01-01, 9999-12-31).
   - Valeurs = version courante (EndDate IS NULL), à défaut la version
     la plus récente (StartDate maximale). Même ordre de tri que celui
     utilisé par 04_scenario.sql pour tdw_scd2.
   - Une valeur non définie dans AdventureWorksDW (ListPrice NULL,
     ProductSubcategoryKey NULL, pas de superviseur) ne produit PAS de
     ligne : une table temporelle n'enregistre que des valeurs définies.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;

DECLARE @debut DATE = '1900-01-01';
DECLARE @fin   DATE = '9999-12-31';

/* ---------------------------------------------------------------------
   Version de référence de chaque produit et de chaque employé
   --------------------------------------------------------------------- */
SELECT ProductAlternateKey, EnglishProductName, ListPrice, ProductSubcategoryKey
INTO   #ProduitRef
FROM  (SELECT p.*,
              ROW_NUMBER() OVER (PARTITION BY p.ProductAlternateKey
                                 ORDER BY CASE WHEN p.EndDate IS NULL THEN 0 ELSE 1 END,
                                          p.StartDate DESC, p.ProductKey DESC) AS rn
       FROM dbo.DimProduct AS p) AS x
WHERE  rn = 1;

/* Superviseur : dans AdventureWorksDW2022, ParentEmployeeNationalIDAlternateKey
   est NULL pour TOUS les employés (vérifié : 0 sur 296), alors que
   ParentEmployeeKey est renseigné (295 sur 296). On retrouve donc l'identifiant
   national du superviseur par une auto-jointure sur ParentEmployeeKey.
   ParentEmployeeKey désigne une VERSION du superviseur ; son identifiant
   national, lui, est stable. */
SELECT EmployeeNationalIDAlternateKey, FirstName, LastName,
       ParentNationalID, SalesTerritoryKey
INTO   #EmployeRef
FROM  (SELECT e.EmployeeNationalIDAlternateKey, e.FirstName, e.LastName,
              par.EmployeeNationalIDAlternateKey AS ParentNationalID,
              e.SalesTerritoryKey,
              ROW_NUMBER() OVER (PARTITION BY e.EmployeeNationalIDAlternateKey
                                 ORDER BY CASE WHEN e.EndDate IS NULL THEN 0 ELSE 1 END,
                                          e.StartDate DESC, e.EmployeeKey DESC) AS rn
       FROM      dbo.DimEmployee AS e
       LEFT JOIN dbo.DimEmployee AS par ON par.EmployeeKey = e.ParentEmployeeKey) AS x
WHERE  rn = 1;

/* =====================================================================
   C2 — Niveau Product
   ===================================================================== */
INSERT INTO tdw.Produit (ProductAlternateKey, NomProduit)
SELECT ProductAlternateKey, EnglishProductName
FROM   #ProduitRef
ORDER BY ProductAlternateKey;

INSERT INTO tdw.ProduitDureeVie (ProduitKey, FromDate, ToDate)
SELECT ProduitKey, @debut, @fin
FROM   tdw.Produit;

INSERT INTO tdw.ProduitPrix (ProduitKey, PrixCatalogue, FromDate, ToDate)
SELECT pr.ProduitKey, r.ListPrice, @debut, @fin
FROM   tdw.Produit AS pr
JOIN   #ProduitRef AS r ON r.ProductAlternateKey = pr.ProductAlternateKey
WHERE  r.ListPrice IS NOT NULL;

INSERT INTO tdw.ProduitSousCategorie (ProduitKey, ProductSubcategoryKey, FromDate, ToDate)
SELECT pr.ProduitKey, r.ProductSubcategoryKey, @debut, @fin
FROM   tdw.Produit AS pr
JOIN   #ProduitRef AS r ON r.ProductAlternateKey = pr.ProductAlternateKey
WHERE  r.ProductSubcategoryKey IS NOT NULL;

INSERT INTO tdw.SousCategorieNom (ProductSubcategoryKey, NomSousCategorie, FromDate, ToDate)
SELECT ProductSubcategoryKey, EnglishProductSubcategoryName, @debut, @fin
FROM   dbo.DimProductSubcategory;

/* =====================================================================
   C2 — Niveau Employee
   ===================================================================== */
INSERT INTO tdw.Employe (EmployeeNationalIDAlternateKey, Prenom, Nom)
SELECT EmployeeNationalIDAlternateKey, FirstName, LastName
FROM   #EmployeRef
ORDER BY EmployeeNationalIDAlternateKey;

/* SuperviseurKey = clé tdw.Employe du superviseur */
INSERT INTO tdw.EmployeSupervision (EmployeKey, SuperviseurKey, FromDate, ToDate)
SELECT em.EmployeKey, sup.EmployeKey, @debut, @fin
FROM   #EmployeRef AS r
JOIN   tdw.Employe AS em  ON em.EmployeeNationalIDAlternateKey  = r.EmployeeNationalIDAlternateKey
JOIN   tdw.Employe AS sup ON sup.EmployeeNationalIDAlternateKey = r.ParentNationalID
WHERE  em.EmployeKey <> sup.EmployeKey;

INSERT INTO tdw.EmployeTerritoire (EmployeKey, SalesTerritoryKey, FromDate, ToDate)
SELECT em.EmployeKey, r.SalesTerritoryKey, @debut, @fin
FROM   #EmployeRef AS r
JOIN   tdw.Employe AS em ON em.EmployeeNationalIDAlternateKey = r.EmployeeNationalIDAlternateKey
WHERE  r.SalesTerritoryKey IS NOT NULL;

/* =====================================================================
   C3 — Table de faits reconstruite sur les clés STABLES (requête imposée)
   ===================================================================== */
SELECT f.SalesOrderNumber, f.SalesOrderLineNumber, f.OrderDateKey,
       pr.ProduitKey, em.EmployeKey, f.ResellerKey,
       f.OrderQuantity, f.SalesAmount
INTO   tdw.Ventes
FROM   dbo.FactResellerSales AS f
JOIN   dbo.DimProduct  AS p  ON p.ProductKey = f.ProductKey
JOIN   tdw.Produit     AS pr ON pr.ProductAlternateKey = p.ProductAlternateKey
JOIN   dbo.DimEmployee AS e  ON e.EmployeeKey = f.EmployeeKey
JOIN   tdw.Employe     AS em ON em.EmployeeNationalIDAlternateKey = e.EmployeeNationalIDAlternateKey;

ALTER TABLE tdw.Ventes ADD
    CONSTRAINT PK_Ventes PRIMARY KEY (SalesOrderNumber, SalesOrderLineNumber),
    CONSTRAINT FK_Ventes_Produit  FOREIGN KEY (ProduitKey)   REFERENCES tdw.Produit (ProduitKey),
    CONSTRAINT FK_Ventes_Employe  FOREIGN KEY (EmployeKey)   REFERENCES tdw.Employe (EmployeKey),
    CONSTRAINT FK_Ventes_Date     FOREIGN KEY (OrderDateKey) REFERENCES dbo.DimDate (DateKey),
    CONSTRAINT FK_Ventes_Reseller FOREIGN KEY (ResellerKey)  REFERENCES dbo.DimReseller (ResellerKey);

/* =====================================================================
   C4 — Copies SCD de type 2 (requêtes imposées, telles quelles)
   SELECT ... INTO conserve la propriété IDENTITY de ProductKey :
   le scénario s'en sert pour créer de nouvelles versions.
   ===================================================================== */
SELECT ProductKey, ProductAlternateKey, EnglishProductName, ProductSubcategoryKey,
       ListPrice, StartDate, EndDate, Status
INTO   tdw_scd2.DimProduit
FROM   dbo.DimProduct;

SELECT SalesOrderNumber, SalesOrderLineNumber, OrderDateKey, ProductKey,
       EmployeeKey, ResellerKey, OrderQuantity, SalesAmount
INTO   tdw_scd2.Ventes
FROM   dbo.FactResellerSales;

ALTER TABLE tdw_scd2.DimProduit ADD
    CONSTRAINT PK_scd2_DimProduit PRIMARY KEY (ProductKey);

ALTER TABLE tdw_scd2.Ventes ADD
    CONSTRAINT PK_scd2_Ventes PRIMARY KEY (SalesOrderNumber, SalesOrderLineNumber),
    CONSTRAINT FK_scd2_Ventes_Produit FOREIGN KEY (ProductKey)
        REFERENCES tdw_scd2.DimProduit (ProductKey);

/* ---------------------------------------------------------------------
   Contrôle C3 : même nombre de lignes et même SUM(SalesAmount).
   En cas d'écart, toute la transaction est annulée.
   --------------------------------------------------------------------- */
DECLARE @nSrc INT, @nTdw INT, @sSrc MONEY, @sTdw MONEY;

SELECT @nSrc = COUNT(*), @sSrc = SUM(SalesAmount) FROM dbo.FactResellerSales;
SELECT @nTdw = COUNT(*), @sTdw = SUM(SalesAmount) FROM tdw.Ventes;

IF @nSrc <> @nTdw OR @sSrc <> @sTdw
    THROW 52000, N'Contrôle C3 échoué : tdw.Ventes ne correspond pas à dbo.FactResellerSales.', 1;

COMMIT TRANSACTION;

DROP TABLE #ProduitRef;
DROP TABLE #EmployeRef;
GO

/* ---------------------------------------------------------------------
   Récapitulatif
   --------------------------------------------------------------------- */
SELECT N'tdw.Produit'              AS TableName, COUNT(*) AS NbLignes FROM tdw.Produit
UNION ALL SELECT N'tdw.ProduitDureeVie',      COUNT(*) FROM tdw.ProduitDureeVie
UNION ALL SELECT N'tdw.ProduitPrix',          COUNT(*) FROM tdw.ProduitPrix
UNION ALL SELECT N'tdw.ProduitSousCategorie', COUNT(*) FROM tdw.ProduitSousCategorie
UNION ALL SELECT N'tdw.SousCategorieNom',     COUNT(*) FROM tdw.SousCategorieNom
UNION ALL SELECT N'tdw.Employe',              COUNT(*) FROM tdw.Employe
UNION ALL SELECT N'tdw.EmployeSupervision',   COUNT(*) FROM tdw.EmployeSupervision
UNION ALL SELECT N'tdw.EmployeTerritoire',    COUNT(*) FROM tdw.EmployeTerritoire
UNION ALL SELECT N'tdw.Ventes',               COUNT(*) FROM tdw.Ventes
UNION ALL SELECT N'tdw_scd2.DimProduit',      COUNT(*) FROM tdw_scd2.DimProduit
UNION ALL SELECT N'tdw_scd2.Ventes',          COUNT(*) FROM tdw_scd2.Ventes;

SELECT (SELECT COUNT(*)         FROM dbo.FactResellerSales) AS NbLignesSource,
       (SELECT COUNT(*)         FROM tdw.Ventes)            AS NbLignesTdw,
       (SELECT SUM(SalesAmount) FROM dbo.FactResellerSales) AS SommeSource,
       (SELECT SUM(SalesAmount) FROM tdw.Ventes)            AS SommeTdw;
GO

PRINT N'03_chargement.sql terminé. Étape suivante : 04_scenario.sql (une seule fois).';
GO