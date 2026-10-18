/* =====================================================================
   02_schema.sql  —  Étape C : schémas tdw et tdw_scd2, tables, contraintes

   - Ne modifie AUCUNE table du schéma dbo.
   - Réexécutable : supprime d'abord tout ce qui a été créé (y compris
     tdw.ScenarioJournal), ce qui permet de rejouer 02 → 03 → 04.
   - Intervalles semi-ouverts [FromDate, ToDate), ToDate = '9999-12-31'
     pour un intervalle encore ouvert (équivalent de « now »).
   - Prérequis : SQL Server 2016+ (DROP TABLE IF EXISTS).
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   0. Nettoyage (ordre compatible avec les clés étrangères)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tdw.ScenarioJournal;
DROP TABLE IF EXISTS tdw.Ventes;
DROP TABLE IF EXISTS tdw.ProduitDureeVie;
DROP TABLE IF EXISTS tdw.ProduitPrix;
DROP TABLE IF EXISTS tdw.ProduitSousCategorie;
DROP TABLE IF EXISTS tdw.SousCategorieNom;
DROP TABLE IF EXISTS tdw.EmployeSupervision;
DROP TABLE IF EXISTS tdw.EmployeTerritoire;
DROP TABLE IF EXISTS tdw.Produit;
DROP TABLE IF EXISTS tdw.Employe;

DROP TABLE IF EXISTS tdw_scd2.Ventes;
DROP TABLE IF EXISTS tdw_scd2.DimProduit;
GO

IF SCHEMA_ID(N'tdw') IS NULL      EXEC (N'CREATE SCHEMA tdw');
IF SCHEMA_ID(N'tdw_scd2') IS NULL EXEC (N'CREATE SCHEMA tdw_scd2');
GO

/* =====================================================================
   1. Niveau Product (Figure 16 : Product, ProductLifespan,
      ProductUnitPrice, ProductCategory)
   ===================================================================== */

/* Niveau Product : attributs non temporels + clé de substitution STABLE.
   Contrairement à dbo.DimProduct.ProductKey (une clé par version SCD 2),
   ProduitKey identifie le membre, indépendamment du temps. */
CREATE TABLE tdw.Produit (
    ProduitKey          INT IDENTITY(1,1) NOT NULL,
    ProductAlternateKey NVARCHAR(25)      NOT NULL,
    NomProduit          NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Produit PRIMARY KEY (ProduitKey),
    CONSTRAINT UQ_Produit_AlternateKey UNIQUE (ProductAlternateKey)
);

/* Durée de vie (lifespan) : ensemble d'intervalles → table séparée */
CREATE TABLE tdw.ProduitDureeVie (
    ProduitKey INT  NOT NULL,
    FromDate   DATE NOT NULL,
    ToDate     DATE NOT NULL,
    CONSTRAINT PK_ProduitDureeVie PRIMARY KEY (ProduitKey, FromDate),
    CONSTRAINT CK_ProduitDureeVie_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT FK_ProduitDureeVie_Produit FOREIGN KEY (ProduitKey)
        REFERENCES tdw.Produit (ProduitKey)
);

/* Attribut temporel UnitPrice → une table par attribut temporel */
CREATE TABLE tdw.ProduitPrix (
    ProduitKey    INT   NOT NULL,
    PrixCatalogue MONEY NOT NULL,
    FromDate      DATE  NOT NULL,
    ToDate        DATE  NOT NULL,
    CONSTRAINT PK_ProduitPrix PRIMARY KEY (ProduitKey, FromDate),
    CONSTRAINT CK_ProduitPrix_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT FK_ProduitPrix_Produit FOREIGN KEY (ProduitKey)
        REFERENCES tdw.Produit (ProduitKey)
);

/* Relation d'agrégation temporelle Product → Subcategory */
CREATE TABLE tdw.ProduitSousCategorie (
    ProduitKey            INT  NOT NULL,
    ProductSubcategoryKey INT  NOT NULL,
    FromDate              DATE NOT NULL,
    ToDate                DATE NOT NULL,
    CONSTRAINT PK_ProduitSousCategorie PRIMARY KEY (ProduitKey, FromDate),
    CONSTRAINT CK_ProduitSousCategorie_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT FK_ProduitSousCategorie_Produit FOREIGN KEY (ProduitKey)
        REFERENCES tdw.Produit (ProduitKey),
    CONSTRAINT FK_ProduitSousCategorie_SousCategorie FOREIGN KEY (ProductSubcategoryKey)
        REFERENCES dbo.DimProductSubcategory (ProductSubcategoryKey)
);

/* Attribut temporel du niveau Subcategory (équivalent de CategoryDescription).
   Le niveau lui-même reste non temporel dans dbo.DimProductSubcategory. */
CREATE TABLE tdw.SousCategorieNom (
    ProductSubcategoryKey INT          NOT NULL,
    NomSousCategorie      NVARCHAR(50) NOT NULL,
    FromDate              DATE         NOT NULL,
    ToDate                DATE         NOT NULL,
    CONSTRAINT PK_SousCategorieNom PRIMARY KEY (ProductSubcategoryKey, FromDate),
    CONSTRAINT CK_SousCategorieNom_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT FK_SousCategorieNom_SousCategorie FOREIGN KEY (ProductSubcategoryKey)
        REFERENCES dbo.DimProductSubcategory (ProductSubcategoryKey)
);
GO

/* =====================================================================
   2. Niveau Employee (Figure 16 : Employee, EmployeeSupervision,
      Territories)
   ===================================================================== */

CREATE TABLE tdw.Employe (
    EmployeKey                     INT IDENTITY(1,1) NOT NULL,
    EmployeeNationalIDAlternateKey NVARCHAR(15)      NOT NULL,
    Prenom                         NVARCHAR(50)      NOT NULL,
    Nom                            NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Employe PRIMARY KEY (EmployeKey),
    CONSTRAINT UQ_Employe_AlternateKey UNIQUE (EmployeeNationalIDAlternateKey)
);

/* Relation récursive temporelle Employee → Employee (Supervisor) */
CREATE TABLE tdw.EmployeSupervision (
    EmployeKey     INT  NOT NULL,
    SuperviseurKey INT  NOT NULL,
    FromDate       DATE NOT NULL,
    ToDate         DATE NOT NULL,
    CONSTRAINT PK_EmployeSupervision PRIMARY KEY (EmployeKey, FromDate),
    CONSTRAINT CK_EmployeSupervision_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT CK_EmployeSupervision_PasSoiMeme CHECK (EmployeKey <> SuperviseurKey),
    CONSTRAINT FK_EmployeSupervision_Employe FOREIGN KEY (EmployeKey)
        REFERENCES tdw.Employe (EmployeKey),
    CONSTRAINT FK_EmployeSupervision_Superviseur FOREIGN KEY (SuperviseurKey)
        REFERENCES tdw.Employe (EmployeKey)
);

/* Relation temporelle Employee → SalesTerritory (Territories) */
CREATE TABLE tdw.EmployeTerritoire (
    EmployeKey        INT  NOT NULL,
    SalesTerritoryKey INT  NOT NULL,
    FromDate          DATE NOT NULL,
    ToDate            DATE NOT NULL,
    CONSTRAINT PK_EmployeTerritoire PRIMARY KEY (EmployeKey, FromDate),
    CONSTRAINT CK_EmployeTerritoire_Intervalle CHECK (FromDate < ToDate),
    CONSTRAINT FK_EmployeTerritoire_Employe FOREIGN KEY (EmployeKey)
        REFERENCES tdw.Employe (EmployeKey),
    CONSTRAINT FK_EmployeTerritoire_Territoire FOREIGN KEY (SalesTerritoryKey)
        REFERENCES dbo.DimSalesTerritory (SalesTerritoryKey)
);
GO

/* tdw.Ventes, tdw_scd2.DimProduit et tdw_scd2.Ventes sont créées par
   SELECT ... INTO dans 03_chargement.sql (requêtes imposées C3 et C4) ;
   leurs contraintes y sont ajoutées après le chargement. */

/* =====================================================================
   3. BONUS — Contrainte 3: pas de chevauchement d'intervalles
      pour un même membre. L'article propose un déclencheur.
      Deux lignes a, b d'un même membre se chevauchent si
      a.FromDate < b.FromDate < a.ToDate (FromDate est unique par membre
      grâce à la clé primaire). Compatible avec le scénario, qui
      clôture toujours l'ancien intervalle (UPDATE) AVANT d'insérer le
      nouveau (INSERT).
   ===================================================================== */

CREATE TRIGGER tdw.trg_ProduitDureeVie_Chevauchement
ON tdw.ProduitDureeVie AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.ProduitDureeVie AS a
               JOIN tdw.ProduitDureeVie AS b
                 ON b.ProduitKey = a.ProduitKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.ProduitKey IN (SELECT ProduitKey FROM inserted))
        THROW 51001, N'tdw.ProduitDureeVie : intervalles qui se chevauchent pour un même produit.', 1;
END;
GO

CREATE TRIGGER tdw.trg_ProduitPrix_Chevauchement
ON tdw.ProduitPrix AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.ProduitPrix AS a
               JOIN tdw.ProduitPrix AS b
                 ON b.ProduitKey = a.ProduitKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.ProduitKey IN (SELECT ProduitKey FROM inserted))
        THROW 51002, N'tdw.ProduitPrix : intervalles qui se chevauchent pour un même produit.', 1;
END;
GO

CREATE TRIGGER tdw.trg_ProduitSousCategorie_Chevauchement
ON tdw.ProduitSousCategorie AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.ProduitSousCategorie AS a
               JOIN tdw.ProduitSousCategorie AS b
                 ON b.ProduitKey = a.ProduitKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.ProduitKey IN (SELECT ProduitKey FROM inserted))
        THROW 51003, N'tdw.ProduitSousCategorie : intervalles qui se chevauchent pour un même produit.', 1;
END;
GO

CREATE TRIGGER tdw.trg_SousCategorieNom_Chevauchement
ON tdw.SousCategorieNom AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.SousCategorieNom AS a
               JOIN tdw.SousCategorieNom AS b
                 ON b.ProductSubcategoryKey = a.ProductSubcategoryKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.ProductSubcategoryKey IN (SELECT ProductSubcategoryKey FROM inserted))
        THROW 51004, N'tdw.SousCategorieNom : intervalles qui se chevauchent pour une même sous-catégorie.', 1;
END;
GO

CREATE TRIGGER tdw.trg_EmployeSupervision_Chevauchement
ON tdw.EmployeSupervision AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.EmployeSupervision AS a
               JOIN tdw.EmployeSupervision AS b
                 ON b.EmployeKey = a.EmployeKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.EmployeKey IN (SELECT EmployeKey FROM inserted))
        THROW 51005, N'tdw.EmployeSupervision : intervalles qui se chevauchent pour un même employé.', 1;
END;
GO

CREATE TRIGGER tdw.trg_EmployeTerritoire_Chevauchement
ON tdw.EmployeTerritoire AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM tdw.EmployeTerritoire AS a
               JOIN tdw.EmployeTerritoire AS b
                 ON b.EmployeKey = a.EmployeKey
                AND a.FromDate < b.FromDate AND b.FromDate < a.ToDate
               WHERE a.EmployeKey IN (SELECT EmployeKey FROM inserted))
        THROW 51006, N'tdw.EmployeTerritoire : intervalles qui se chevauchent pour un même employé.', 1;
END;
GO

PRINT N'02_schema.sql terminé : schémas tdw et tdw_scd2 prêts.';
GO