/* =====================================================================
   08_bonus_B1_B2.sql  —  Bonus B1 et B2 (facultatifs)

   À exécuter après 02 → 03 → 04. Indépendant de 05, 06 et 07.
   Tout est créé dans un schéma séparé « bonus » : les tables des
   schémas dbo, tdw et tdw_scd2 ne sont jamais modifiées.
   Réexécutable : chaque partie supprime d'abord ce qu'elle a créé.

   B1 — ProduitPrix en table temporelle système (SYSTEM_VERSIONING = ON)
        et pourquoi le temps système ne remplace pas le temps de validité.
   B2 — Changement de prix mensuel sur 10 produits pendant 24 mois :
        nombre de lignes créées dans le modèle TDW et dans le modèle SCD 2.
   ===================================================================== */

SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'bonus') IS NULL EXEC (N'CREATE SCHEMA bonus');
GO

/* #####################################################################
   B1 — Table temporelle système (p. 139-140)
   ##################################################################### */

/* Nettoyage : une table versionnée doit être « déversionnée » avant DROP */
IF OBJECT_ID(N'bonus.ProduitPrixSysteme', N'U') IS NOT NULL
BEGIN
    IF OBJECTPROPERTY(OBJECT_ID(N'bonus.ProduitPrixSysteme'), 'TableTemporalType') = 2
        ALTER TABLE bonus.ProduitPrixSysteme SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE bonus.ProduitPrixSysteme;
END;
DROP TABLE IF EXISTS bonus.ProduitPrixSystemeHistorique;
GO

/* Une ligne par produit (prix courant) ; SQL Server tient lui-même
   l'historique dans bonus.ProduitPrixSystemeHistorique. */
CREATE TABLE bonus.ProduitPrixSysteme (
    ProduitKey    INT   NOT NULL CONSTRAINT PK_ProduitPrixSysteme PRIMARY KEY,
    PrixCatalogue MONEY NOT NULL,
    DebutSysteme  DATETIME2(0) GENERATED ALWAYS AS ROW START NOT NULL,
    FinSysteme    DATETIME2(0) GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (DebutSysteme, FinSysteme)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = bonus.ProduitPrixSystemeHistorique));
GO

/* 1. État initial : les prix d'avant le scénario (intervalles commençant en 1900).
      Impossible de les dater de 1900 : SQL Server leur donne l'heure
      de l'INSERT, c'est-à-dire aujourd'hui. */
INSERT INTO bonus.ProduitPrixSysteme (ProduitKey, PrixCatalogue)
SELECT ProduitKey, PrixCatalogue
FROM   tdw.ProduitPrix
WHERE  FromDate = '1900-01-01';

WAITFOR DELAY '00:00:02';   -- pour que la nouvelle version ait un horodatage distinct

/* 2. On rejoue l'événement 2 du scénario (+8 % sur les Bikes à @t2) */
DECLARE @t2 DATE = (SELECT MIN(DateEffet) FROM tdw.ScenarioJournal WHERE NumEvenement = 2);

UPDATE ps
SET    ps.PrixCatalogue = ps.PrixCatalogue * 1.08
FROM   bonus.ProduitPrixSysteme AS ps
WHERE  ps.ProduitKey IN (SELECT ProduitKey FROM tdw.ProduitPrix WHERE FromDate = @t2);

/* 3a. L'historique est daté au moment de l'UPDATE (aujourd'hui), pas à @t2 */
DECLARE @unVelo INT = (SELECT MIN(ProduitKey) FROM tdw.ProduitPrix WHERE FromDate = @t2);

SELECT N'B1 — versions système d''un vélo' AS Demo,
       ProduitKey, PrixCatalogue, DebutSysteme, FinSysteme,
       @t2 AS DateDeValiditeReelle
FROM   bonus.ProduitPrixSysteme FOR SYSTEM_TIME ALL
WHERE  ProduitKey = @unVelo
ORDER BY DebutSysteme;

/* 3b. Question métier : « quel était le prix au 2012-07-01 ? »
       Temps système : aucune ligne (la table n'existait pas en 2012).
       Temps de validité (modèle TDW) : réponse correcte. */
SELECT N'B1 — prix au 2012-07-01' AS Demo,
       (SELECT COUNT(*) FROM bonus.ProduitPrixSysteme FOR SYSTEM_TIME AS OF '2012-07-01')
           AS NbPrixTempsSysteme,
       (SELECT COUNT(*) FROM tdw.ProduitPrix
        WHERE FromDate <= '2012-07-01' AND '2012-07-01' < ToDate)
           AS NbPrixTempsValidite;

/* 3c. Correction rétroactive impossible : les colonnes de période sont
       en lecture seule (exécuté en SQL dynamique pour capter l'erreur). */
BEGIN TRY
    EXEC (N'UPDATE bonus.ProduitPrixSysteme SET DebutSysteme = ''2012-06-01'' WHERE ProduitKey = '
          + N'(SELECT MIN(ProduitKey) FROM bonus.ProduitPrixSysteme);');
    SELECT N'B1 — modification de DebutSysteme' AS Demo, N'acceptée (inattendu)' AS Resultat;
END TRY
BEGIN CATCH
    SELECT N'B1 — modification de DebutSysteme' AS Demo,
           ERROR_NUMBER() AS NumErreur, ERROR_MESSAGE() AS MessageErreur;
END CATCH;
GO

/* #####################################################################
   B2 — 24 changements de prix mensuels sur 10 produits (p. 139)

   Les changements sont simulés APRÈS la dernière vente et après la
   dernière version existante : c'est le cas réel d'un entrepôt qui
   reçoit de nouveaux prix. Aucune vente passée n'a donc à être
   réaffectée en SCD 2 (contrairement au scénario, qui réécrit le passé).

   On travaille sur des copies : bonus.B2_TDW_ProduitPrix et
   bonus.B2_SCD2_DimProduit (SELECT ... INTO conserve l'IDENTITY de
   ProductKey, nécessaire pour créer de nouvelles versions).
   ##################################################################### */
DROP TABLE IF EXISTS bonus.B2_TDW_ProduitPrix;
DROP TABLE IF EXISTS bonus.B2_SCD2_DimProduit;
GO

SELECT * INTO bonus.B2_TDW_ProduitPrix FROM tdw.ProduitPrix;
SELECT * INTO bonus.B2_SCD2_DimProduit FROM tdw_scd2.DimProduit;
GO

/* 10 produits : les plus vendus, ayant un prix ouvert en TDW et une
   version courante avec prix en SCD 2 */
DECLARE @produits TABLE (ProduitKey INT PRIMARY KEY, ProductAlternateKey NVARCHAR(25));

INSERT INTO @produits (ProduitKey, ProductAlternateKey)
SELECT TOP (10) pr.ProduitKey, pr.ProductAlternateKey
FROM   tdw.Produit AS pr
JOIN   tdw.Ventes  AS v ON v.ProduitKey = pr.ProduitKey
WHERE  EXISTS (SELECT 1 FROM bonus.B2_TDW_ProduitPrix AS pp
               WHERE pp.ProduitKey = pr.ProduitKey AND pp.ToDate = '9999-12-31')
  AND  EXISTS (SELECT 1 FROM bonus.B2_SCD2_DimProduit AS dp
               WHERE dp.ProductAlternateKey = pr.ProductAlternateKey
                 AND dp.EndDate IS NULL AND dp.ListPrice IS NOT NULL)
GROUP BY pr.ProduitKey, pr.ProductAlternateKey
ORDER BY SUM(v.SalesAmount) DESC;

/* Premier mois simulé : le mois qui suit la dernière date connue */
DECLARE @max DATE = (
    SELECT MAX(x) FROM (VALUES
        ((SELECT MAX(d.FullDateAlternateKey) FROM tdw.Ventes AS v
          JOIN dbo.DimDate AS d ON d.DateKey = v.OrderDateKey)),
        ((SELECT CAST(MAX(StartDate) AS DATE) FROM bonus.B2_SCD2_DimProduit)),
        ((SELECT MAX(FromDate) FROM bonus.B2_TDW_ProduitPrix))
    ) AS t(x));
DECLARE @debutSim DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@max), MONTH(@max), 1));

DECLARE @avantTDW INT = (SELECT COUNT(*) FROM bonus.B2_TDW_ProduitPrix);
DECLARE @avantSCD INT = (SELECT COUNT(*) FROM bonus.B2_SCD2_DimProduit);

DECLARE @tdwIns INT = 0, @tdwUpd INT = 0, @scdIns INT = 0, @scdUpd INT = 0,
        @faits INT = 0, @i INT = 0, @m DATE;
DECLARE @fermes    TABLE (ProduitKey INT, Prix MONEY, AncienneFin DATE);
DECLARE @anciennes TABLE (ProductKey INT PRIMARY KEY);

WHILE @i < 24
BEGIN
    SET @m = DATEADD(MONTH, @i, @debutSim);

    /* --- TDW : clôturer l'intervalle en cours, ouvrir le nouveau (+1 %) --- */
    DELETE FROM @fermes;

    UPDATE pp
    SET    pp.ToDate = @m
    OUTPUT deleted.ProduitKey, deleted.PrixCatalogue, deleted.ToDate INTO @fermes
    FROM   bonus.B2_TDW_ProduitPrix AS pp
    JOIN   @produits AS p ON p.ProduitKey = pp.ProduitKey
    WHERE  pp.FromDate < @m AND @m < pp.ToDate;
    SET @tdwUpd += @@ROWCOUNT;

    INSERT INTO bonus.B2_TDW_ProduitPrix (ProduitKey, PrixCatalogue, FromDate, ToDate)
    SELECT ProduitKey, ROUND(Prix * 1.01, 2), @m, AncienneFin
    FROM   @fermes;
    SET @tdwIns += @@ROWCOUNT;

    /* --- SCD 2 : nouvelle version complète (nouvelle clé), clôture de l'ancienne --- */
    DELETE FROM @anciennes;

    INSERT INTO @anciennes (ProductKey)
    SELECT dp.ProductKey
    FROM   bonus.B2_SCD2_DimProduit AS dp
    JOIN   @produits AS p ON p.ProductAlternateKey = dp.ProductAlternateKey
    WHERE  dp.EndDate IS NULL;

    INSERT INTO bonus.B2_SCD2_DimProduit
           (ProductAlternateKey, EnglishProductName, ProductSubcategoryKey,
            ListPrice, StartDate, EndDate, Status)
    SELECT dp.ProductAlternateKey, dp.EnglishProductName, dp.ProductSubcategoryKey,
           ROUND(dp.ListPrice * 1.01, 2), @m, NULL, N'Current'
    FROM   bonus.B2_SCD2_DimProduit AS dp
    JOIN   @anciennes AS a ON a.ProductKey = dp.ProductKey;
    SET @scdIns += @@ROWCOUNT;

    UPDATE dp
    SET    dp.EndDate = DATEADD(DAY, -1, @m),
           dp.Status  = NULL
    FROM   bonus.B2_SCD2_DimProduit AS dp
    JOIN   @anciennes AS a ON a.ProductKey = dp.ProductKey;
    SET @scdUpd += @@ROWCOUNT;

    /* Ventes postérieures à @m qu'il faudrait réaffecter en SCD 2 (attendu : 0) */
    SET @faits += (SELECT COUNT(*)
                   FROM   tdw.Ventes AS v
                   JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
                   JOIN   @produits AS p ON p.ProduitKey = v.ProduitKey
                   WHERE  d.FullDateAlternateKey >= @m);

    SET @i += 1;
END;

/* Résultat 1 : lignes créées et modifiées dans chaque modèle */
SELECT N'B2 — période simulée' AS Info, @debutSim AS PremierMois, @m AS DernierMois,
       (SELECT COUNT(*) FROM @produits) AS NbProduits;

SELECT N'TDW (table ProduitPrix)'  AS Modele,
       @avantTDW AS LignesAvant, (SELECT COUNT(*) FROM bonus.B2_TDW_ProduitPrix) AS LignesApres,
       @tdwIns AS LignesInserees, @tdwUpd AS LignesModifiees, 0 AS FaitsReaffectes
UNION ALL
SELECT N'SCD 2 (table DimProduit)',
       @avantSCD, (SELECT COUNT(*) FROM bonus.B2_SCD2_DimProduit),
       @scdIns, @scdUpd, @faits;
GO

/* Résultat 2 : taille moyenne d'une ligne (octets) — une version SCD 2
   recopie toute la ligne du produit ; une ligne TDW ne contient que
   (clé, prix, FromDate, ToDate). dbo.DimProduct est la table SCD 2
   complète d'AdventureWorksDW (avec toutes ses colonnes, photo comprise). */
SELECT s.TableName,
       SUM(p.row_count)                                        AS NbLignes,
       CAST(SUM(p.used_page_count) * 8192.0
            / NULLIF(SUM(p.row_count), 0) AS DECIMAL(12,1))    AS OctetsParLigneMoyen
FROM  (VALUES (N'tdw.ProduitPrix'),
              (N'bonus.B2_TDW_ProduitPrix'),
              (N'tdw_scd2.DimProduit'),
              (N'bonus.B2_SCD2_DimProduit'),
              (N'dbo.DimProduct')) AS s(TableName)
JOIN   sys.dm_db_partition_stats AS p
       ON  p.object_id = OBJECT_ID(s.TableName)
       AND p.index_id IN (0, 1)          -- tas ou index cluster (données)
GROUP BY s.TableName
ORDER BY s.TableName;
GO
