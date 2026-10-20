/* =====================================================================
   05_requetes.sql  —  Étape E : requêtes R1 à R5

   À exécuter après 02 → 03 → 04 (le scénario doit avoir été joué :
   les dates @t1..@t4 sont lues dans tdw.ScenarioJournal).

   R1, R2, R3 : modèles TDW et SCD 2   (comparés dans 07_tests.sql)
   R4, R5     : modèle TDW uniquement
   Bonus      : R6, R7, R8 (lecture seule), puis B1, B2 (écriture dans
                le seul schéma « bonus »)

   Règle de comparaison : on regroupe par ProductSubcategoryKey et non
   par le nom (le renommage de @t3 n'existe que dans le modèle TDW).
   Le nom affiché vient de dbo.DimProductSubcategory (non versionnée),
   identique dans les deux modèles, pour la lisibilité uniquement.

   Conventions d'intervalles :
     - TDW      : semi-ouverts [FromDate, ToDate), ToDate = '9999-12-31' = now
     - SCD 2    : fermés [StartDate, EndDate], EndDate NULL = version courante
                  (convention d'AdventureWorksDW, reprise par le scénario)
   ===================================================================== */

SET NOCOUNT ON;
GO

/* =====================================================================
   R1 — Roll-up temporellement cohérent (Exemple 16, Figure 13)
   Chiffre d'affaires annuel par sous-catégorie, selon l'affectation
   valide à la date de la commande.
   ===================================================================== */

/* R1 — TDW : la dernière condition est celle de la requête 2 (p. 136) */
SELECT ps.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       d.CalendarYear                   AS Annee,
       SUM(v.SalesAmount)               AS ChiffreAffaires
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= d.FullDateAlternateKey
       AND d.FullDateAlternateKey < ps.ToDate
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = ps.ProductSubcategoryKey
GROUP BY ps.ProductSubcategoryKey, sc.EnglishProductSubcategoryName, d.CalendarYear
ORDER BY Annee, ps.ProductSubcategoryKey;

/* R1 — SCD 2 : chaque vente pointe déjà vers la version valide à sa date
   (le scénario a réaffecté les ventes >= @t1 à la nouvelle version).
   Aucune condition temporelle n'est nécessaire. */
SELECT p.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       d.CalendarYear                   AS Annee,
       SUM(v.SalesAmount)               AS ChiffreAffaires
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d          ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p  ON p.ProductKey = v.ProductKey
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = p.ProductSubcategoryKey
GROUP BY p.ProductSubcategoryKey, sc.EnglishProductSubcategoryName, d.CalendarYear
ORDER BY Annee, p.ProductSubcategoryKey;
GO

/* =====================================================================
   R2 — Roll-up time-slice « maintenant » (Exemple 16, Figure 14)
   Chiffre d'affaires annuel par sous-catégorie, selon l'affectation
   actuelle.
   ===================================================================== */

/* R2 — TDW : seule la condition temporelle change par rapport à R1.
   L'état « now » est l'intervalle encore ouvert (ToDate = '9999-12-31'). */
SELECT ps.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       d.CalendarYear                   AS Annee,
       SUM(v.SalesAmount)               AS ChiffreAffaires
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.ToDate = '9999-12-31'
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = ps.ProductSubcategoryKey
GROUP BY ps.ProductSubcategoryKey, sc.EnglishProductSubcategoryName, d.CalendarYear
ORDER BY Annee, ps.ProductSubcategoryKey;

/* R2 — SCD 2 : il faut remonter de la version vendue au produit
   (ProductAlternateKey), puis redescendre vers SA version courante.

   Version courante = EndDate IS NULL ; à défaut (produit sans version
   courante, p. ex. retiré du catalogue), la version la plus récente.
   Si deux versions ont EndDate IS NULL, on garde la plus récente.
   C'est exactement l'ordre de tri utilisé par 03_chargement.sql (C2)
   et par 04_scenario.sql : sans cette règle, les ventes des produits
   sans version courante disparaîtraient silencieusement du résultat. */
WITH VersionCourante AS (
    SELECT ProductAlternateKey, ProductSubcategoryKey,
           ROW_NUMBER() OVER (PARTITION BY ProductAlternateKey
                              ORDER BY CASE WHEN EndDate IS NULL THEN 0 ELSE 1 END,
                                       StartDate DESC, ProductKey DESC) AS rn
    FROM   tdw_scd2.DimProduit
)
SELECT c.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       d.CalendarYear                   AS Annee,
       SUM(v.SalesAmount)               AS ChiffreAffaires
FROM   tdw_scd2.Ventes AS v
JOIN   dbo.DimDate AS d         ON d.DateKey = v.OrderDateKey
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey                 -- version vendue
JOIN   VersionCourante AS c     ON c.ProductAlternateKey = p.ProductAlternateKey
                               AND c.rn = 1                                    -- version courante du même produit
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = c.ProductSubcategoryKey
GROUP BY c.ProductSubcategoryKey, sc.EnglishProductSubcategoryName, d.CalendarYear
ORDER BY Annee, c.ProductSubcategoryKey;
GO

/* =====================================================================
   R3 — Roll-up time-slice à une date (requête 1, p. 136)
   Montant moyen d'une ligne de vente par sous-catégorie, selon
   l'affectation valide la veille de @t1.
   ===================================================================== */

DECLARE @t1     DATE = (SELECT MIN(DateEffet) FROM tdw.ScenarioJournal WHERE NumEvenement = 1);
DECLARE @veille DATE = DATEADD(DAY, -1, @t1);

/* R3 — TDW : même gabarit que R1/R2, avec un instant fixe */
SELECT ps.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       AVG(v.SalesAmount)               AS MontantMoyenLigne,
       COUNT(*)                         AS NbLignes
FROM   tdw.Ventes AS v
JOIN   tdw.ProduitSousCategorie AS ps
       ON  ps.ProduitKey = v.ProduitKey
       AND ps.FromDate <= @veille
       AND @veille < ps.ToDate
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = ps.ProductSubcategoryKey
GROUP BY ps.ProductSubcategoryKey, sc.EnglishProductSubcategoryName
ORDER BY ps.ProductSubcategoryKey;

/* R3 — SCD 2 : pour chaque produit, la version valide à @veille.
   Intervalle FERMÉ dans AdventureWorksDW : StartDate <= @veille <= EndDate.

   Cas particuliers (documentés, voir README et rapport) :
   - aucune version valide à @veille : on retient la version la plus
     ancienne, c'est-à-dire l'état connu le plus proche, ce qui correspond
     à l'hypothèse C2 du modèle TDW (état initial supposé valide depuis
     1900). C'est le cas de la PLUPART des produits : dans
     AdventureWorksDW, les StartDate ont été décalées mais pas les
     EndDate (EndDate antérieure à StartDate, cf. B1/B4 : 48 954 ventes
     sur 60 855 hors validité). Sans cette règle, R3 serait fausse ;
   - plusieurs versions valides (chevauchement) : on retient la plus
     récente des versions valides. */
WITH VersionALaDate AS (
    SELECT ProductAlternateKey, ProductSubcategoryKey,
           ROW_NUMBER() OVER (
               PARTITION BY ProductAlternateKey
               ORDER BY CASE WHEN CAST(StartDate AS DATE) <= @veille
                              AND (EndDate IS NULL OR @veille <= CAST(EndDate AS DATE))
                             THEN 0 ELSE 1 END,                               -- versions valides d'abord
                        CASE WHEN CAST(StartDate AS DATE) <= @veille
                              AND (EndDate IS NULL OR @veille <= CAST(EndDate AS DATE))
                             THEN StartDate END DESC,                         -- parmi elles, la plus récente
                        StartDate ASC,                                        -- sinon, la plus ancienne
                        ProductKey ASC) AS rn
    FROM   tdw_scd2.DimProduit
)
SELECT a.ProductSubcategoryKey,
       sc.EnglishProductSubcategoryName AS SousCategorie,
       AVG(v.SalesAmount)               AS MontantMoyenLigne,
       COUNT(*)                         AS NbLignes
FROM   tdw_scd2.Ventes AS v
JOIN   tdw_scd2.DimProduit AS p ON p.ProductKey = v.ProductKey
JOIN   VersionALaDate AS a      ON a.ProductAlternateKey = p.ProductAlternateKey
                               AND a.rn = 1
JOIN   dbo.DimProductSubcategory AS sc ON sc.ProductSubcategoryKey = a.ProductSubcategoryKey
GROUP BY a.ProductSubcategoryKey, sc.EnglishProductSubcategoryName
ORDER BY a.ProductSubcategoryKey;
GO

/* =====================================================================
   R4 — Dice temporel sur un attribut temporel (requête 4, p. 137-138)
   Pour chaque vendeur, chiffre d'affaires des produits dont le prix
   catalogue dépassait 1 000 à la date de la vente.
   (TDW uniquement) — la hausse de 8 % de @t2 fait franchir le seuil
   à certains vélos : leurs ventes ne comptent qu'à partir de @t2.
   ===================================================================== */
SELECT e.EmployeKey,
       e.Prenom + N' ' + e.Nom AS Vendeur,
       SUM(v.SalesAmount)      AS ChiffreAffaires,
       COUNT(*)                AS NbLignes
FROM   tdw.Ventes AS v
JOIN   dbo.DimDate AS d     ON d.DateKey = v.OrderDateKey
JOIN   tdw.Employe AS e     ON e.EmployeKey = v.EmployeKey
JOIN   tdw.ProduitPrix AS pp
       ON  pp.ProduitKey = v.ProduitKey
       AND pp.FromDate <= d.FullDateAlternateKey
       AND d.FullDateAlternateKey < pp.ToDate
WHERE  pp.PrixCatalogue > 1000
GROUP BY e.EmployeKey, e.Prenom, e.Nom
ORDER BY ChiffreAffaires DESC;
GO

/* =====================================================================
   R5 — Projection temporelle et coalescing (requête 5, p. 138)
   Pour chaque superviseur, chiffre d'affaires réalisé par lui-même
   pendant les périodes où il supervisait au moins un employé.
   (TDW uniquement)

   L'article ne donne pas le coalescing (« -- Coalescing the table ...
   above »). Méthode : trier les périodes de chaque superviseur ; une
   période ouvre un nouveau groupe si elle commence APRÈS la fin la plus
   tardive des périodes précédentes (ni chevauchement, ni contact) ;
   chaque groupe est fusionné en [MIN(FromDate), MAX(ToDate)).
   ===================================================================== */

/* R5 — avec coalescing (résultat correct) */
WITH Superviseurs AS (            -- une ligne par (superviseur, subordonné, période)
    SELECT SuperviseurKey AS EmployeKey, FromDate, ToDate
    FROM   tdw.EmployeSupervision
),
Marques AS (                      -- 1 = début d'un nouveau groupe d'intervalles
    SELECT EmployeKey, FromDate, ToDate,
           CASE WHEN FromDate <= MAX(ToDate) OVER (
                         PARTITION BY EmployeKey ORDER BY FromDate, ToDate
                         ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                THEN 0 ELSE 1 END AS NouveauGroupe
    FROM   Superviseurs
),
Groupes AS (                      -- numéro de groupe = somme cumulée des débuts
    SELECT *, SUM(NouveauGroupe) OVER (
                  PARTITION BY EmployeKey ORDER BY FromDate, ToDate
                  ROWS UNBOUNDED PRECEDING) AS Groupe
    FROM   Marques
),
SuperviseursCoalesces AS (        -- une ligne par période continue de supervision
    SELECT EmployeKey, MIN(FromDate) AS FromDate, MAX(ToDate) AS ToDate
    FROM   Groupes
    GROUP BY EmployeKey, Groupe
)
SELECT e.EmployeKey,
       e.Prenom + N' ' + e.Nom AS Superviseur,
       u.FromDate, u.ToDate,
       SUM(v.SalesAmount)      AS ChiffreAffaires,
       COUNT(*)                AS NbLignes
FROM   SuperviseursCoalesces AS u
JOIN   tdw.Employe AS e ON e.EmployeKey = u.EmployeKey
JOIN   tdw.Ventes  AS v ON v.EmployeKey = u.EmployeKey          -- ventes du superviseur lui-même
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
WHERE  u.FromDate <= d.FullDateAlternateKey
  AND  d.FullDateAlternateKey < u.ToDate
GROUP BY e.EmployeKey, e.Prenom, e.Nom, u.FromDate, u.ToDate
ORDER BY Superviseur, u.FromDate;

/* R5 — SANS coalescing (pour le rapport : montre l'erreur évitée).
   Un superviseur apparaît dans autant de lignes qu'il a de subordonnés :
   chacune de ses ventes est donc comptée autant de fois. */
WITH Superviseurs AS (
    SELECT SuperviseurKey AS EmployeKey, FromDate, ToDate
    FROM   tdw.EmployeSupervision
)
SELECT e.EmployeKey,
       e.Prenom + N' ' + e.Nom AS Superviseur,
       SUM(v.SalesAmount)      AS ChiffreAffairesGonfle,
       COUNT(*)                AS NbLignesGonfle
FROM   Superviseurs AS u
JOIN   tdw.Employe AS e ON e.EmployeKey = u.EmployeKey
JOIN   tdw.Ventes  AS v ON v.EmployeKey = u.EmployeKey
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
WHERE  u.FromDate <= d.FullDateAlternateKey
  AND  d.FullDateAlternateKey < u.ToDate
GROUP BY e.EmployeKey, e.Prenom, e.Nom
ORDER BY Superviseur;
GO

/* #####################################################################
   BONUS (facultatif) — R6, R7, R8
   ##################################################################### */

/* =====================================================================
   Fonctions dbo.MaxDate / dbo.MinDate (requête 3, p. 137)
   L'article les utilise sans les définir. GREATEST / LEAST n'existent
   qu'à partir de SQL Server 2022 ; ces fonctions rendent le script
   compatible avec SQL Server 2016+ (et Azure SQL Edge).
   (Ce ne sont pas des tables : la règle « ne pas modifier dbo » est
   respectée.)
   ===================================================================== */
CREATE OR ALTER FUNCTION dbo.MaxDate (@a DATE, @b DATE)
RETURNS DATE
AS
BEGIN
    RETURN CASE WHEN @a >= @b THEN @a ELSE @b END;
END;
GO

CREATE OR ALTER FUNCTION dbo.MinDate (@a DATE, @b DATE)
RETURNS DATE
AS
BEGIN
    RETURN CASE WHEN @a <= @b THEN @a ELSE @b END;
END;
GO

/* =====================================================================
   R6 — Union temporelle et coalescing (requête 6, p. 139)
   Chiffre d'affaires des produits qui, à la date de la vente,
   appartenaient à Jerseys ou à Vests.

   Pour les 3 produits déplacés à @t1, les périodes « Jerseys »
   [1900, @t1) et « Vests » [@t1, 9999) se touchent : le coalescing les
   fusionne en une seule période. Contrairement à R5, le coalescing ne
   change pas le total ici (les périodes sont disjointes) ; il évite de
   présenter artificiellement deux périodes pour un même produit.
   ===================================================================== */
DECLARE @scJerseys INT = (SELECT ProductSubcategoryKey FROM dbo.DimProductSubcategory
                          WHERE EnglishProductSubcategoryName = N'Jerseys');
DECLARE @scVests   INT = (SELECT ProductSubcategoryKey FROM dbo.DimProductSubcategory
                          WHERE EnglishProductSubcategoryName = N'Vests');

WITH JerseysOuVests AS (          -- union temporelle des deux affectations
    SELECT ProduitKey, FromDate, ToDate
    FROM   tdw.ProduitSousCategorie
    WHERE  ProductSubcategoryKey IN (@scJerseys, @scVests)
),
Marques AS (
    SELECT ProduitKey, FromDate, ToDate,
           CASE WHEN FromDate <= MAX(ToDate) OVER (
                         PARTITION BY ProduitKey ORDER BY FromDate, ToDate
                         ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                THEN 0 ELSE 1 END AS NouveauGroupe
    FROM   JerseysOuVests
),
Groupes AS (
    SELECT *, SUM(NouveauGroupe) OVER (
                  PARTITION BY ProduitKey ORDER BY FromDate, ToDate
                  ROWS UNBOUNDED PRECEDING) AS Groupe
    FROM   Marques
),
JerseysOuVestsCoalesces AS (
    SELECT ProduitKey, MIN(FromDate) AS FromDate, MAX(ToDate) AS ToDate
    FROM   Groupes
    GROUP BY ProduitKey, Groupe
)
SELECT pr.ProduitKey, pr.ProductAlternateKey, pr.NomProduit,
       c.FromDate, c.ToDate,
       SUM(v.SalesAmount) AS ChiffreAffaires,
       COUNT(*)           AS NbLignes
FROM   JerseysOuVestsCoalesces AS c
JOIN   tdw.Produit AS pr ON pr.ProduitKey = c.ProduitKey
JOIN   tdw.Ventes  AS v  ON v.ProduitKey  = c.ProduitKey
JOIN   dbo.DimDate AS d  ON d.DateKey     = v.OrderDateKey
WHERE  c.FromDate <= d.FullDateAlternateKey
  AND  d.FullDateAlternateKey < c.ToDate
GROUP BY pr.ProduitKey, pr.ProductAlternateKey, pr.NomProduit, c.FromDate, c.ToDate
ORDER BY pr.ProductAlternateKey, c.FromDate;

/* R6 — contrôle : avec et sans coalescing, même total, nombre de périodes différent */
SELECT N'Sans coalescing' AS Variante,
       COUNT(DISTINCT CONCAT(ps.ProduitKey, N'|', ps.FromDate)) AS NbPeriodes,
       SUM(v.SalesAmount) AS ChiffreAffaires
FROM   tdw.ProduitSousCategorie AS ps
JOIN   tdw.Ventes  AS v ON v.ProduitKey = ps.ProduitKey
JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
WHERE  ps.ProductSubcategoryKey IN (@scJerseys, @scVests)
  AND  ps.FromDate <= d.FullDateAlternateKey AND d.FullDateAlternateKey < ps.ToDate;
GO

/* =====================================================================
   R7 — Roll-up récursif (requête 3, p. 136-137)
   Pour une année donnée, ventes personnelles d'un employé et ventes
   cumulées avec ses subordonnés (directs et indirects).

   L'article laisse le roll-up récursif aux travaux futurs (p. 141) et
   le simule par une requête récursive. Supervision = fermeture
   transitive TEMPORELLE de EmployeSupervision : la paire
   (employé, supérieur indirect) n'est valide que sur l'intersection
   des intervalles des maillons (dbo.MaxDate / dbo.MinDate).

   Écart volontaire avec l'article : FULL OUTER JOIN entre ventes
   personnelles et ventes des subordonnés, pour inclure les managers
   sans ventes personnelles (sinon ils disparaissent du résultat).
   Année 2012 : elle contient @t4 (changement de superviseur).
   ===================================================================== */
DECLARE @annee INT = 2012;

WITH Supervision AS (
    SELECT EmployeKey, SuperviseurKey, FromDate, ToDate, 1 AS Niveau
    FROM   tdw.EmployeSupervision
    UNION ALL
    SELECT s.EmployeKey, e.SuperviseurKey,
           dbo.MaxDate(s.FromDate, e.FromDate),
           dbo.MinDate(s.ToDate,   e.ToDate),
           s.Niveau + 1
    FROM   Supervision AS s
    JOIN   tdw.EmployeSupervision AS e ON e.EmployeKey = s.SuperviseurKey
    WHERE  dbo.MaxDate(s.FromDate, e.FromDate) < dbo.MinDate(s.ToDate, e.ToDate)
),
VentesAnnee AS (
    SELECT v.EmployeKey, d.FullDateAlternateKey AS DateVente, v.SalesAmount
    FROM   tdw.Ventes AS v
    JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
    WHERE  d.CalendarYear = @annee
),
VentesPerso AS (
    SELECT EmployeKey, SUM(SalesAmount) AS Montant
    FROM   VentesAnnee
    GROUP BY EmployeKey
),
VentesSubordonnes AS (            -- roll-up temporellement cohérent : supérieur valide à la date de la vente
    SELECT s.SuperviseurKey AS EmployeKey, SUM(va.SalesAmount) AS Montant
    FROM   VentesAnnee AS va
    JOIN   Supervision AS s
           ON  s.EmployeKey = va.EmployeKey
           AND s.FromDate <= va.DateVente
           AND va.DateVente < s.ToDate
    GROUP BY s.SuperviseurKey
)
SELECT e.EmployeKey,
       e.Prenom + N' ' + e.Nom                          AS Employe,
       ISNULL(p.Montant, 0)                             AS VentesPersonnelles,
       ISNULL(p.Montant, 0) + ISNULL(s.Montant, 0)      AS VentesAvecSubordonnes
FROM   VentesPerso AS p
FULL OUTER JOIN VentesSubordonnes AS s ON s.EmployeKey = p.EmployeKey
JOIN   tdw.Employe AS e ON e.EmployeKey = COALESCE(p.EmployeKey, s.EmployeKey)
ORDER BY VentesAvecSubordonnes DESC
OPTION (MAXRECURSION 100);

/* R7 — contrôle : le sommet de la hiérarchie doit cumuler tout le CA de l'année */
SELECT @annee AS Annee,
       (SELECT SUM(v.SalesAmount) FROM tdw.Ventes AS v
        JOIN dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
        WHERE d.CalendarYear = @annee) AS CATotalAnnee;
GO

/* =====================================================================
   R8 — Drill-across (Définition 16)
   Ventes aux revendeurs et ventes Internet (FactInternetSales) par
   produit et par mois.

   Les deux faits sont d'abord agrégés séparément au même grain
   (produit stable, année, mois), puis rapprochés : joindre avant
   d'agréger multiplierait les lignes. FactInternetSales pointe vers des
   VERSIONS de produit (SCD 2) : on remonte au produit stable par
   ProductAlternateKey, comme pour tdw.Ventes (C3).

   La Définition 16 est une équijointure (cellules présentes dans les
   deux faits) ; on utilise ici un FULL OUTER JOIN pour ne perdre aucune
   vente, et le contrôle ci-dessous donne le nombre de cellules communes.
   ===================================================================== */
WITH Revendeurs AS (
    SELECT v.ProduitKey, d.CalendarYear AS Annee, d.MonthNumberOfYear AS Mois,
           SUM(v.SalesAmount) AS CARevendeurs
    FROM   tdw.Ventes AS v
    JOIN   dbo.DimDate AS d ON d.DateKey = v.OrderDateKey
    GROUP BY v.ProduitKey, d.CalendarYear, d.MonthNumberOfYear
),
Internet AS (
    SELECT pr.ProduitKey, d.CalendarYear AS Annee, d.MonthNumberOfYear AS Mois,
           SUM(f.SalesAmount) AS CAInternet
    FROM   dbo.FactInternetSales AS f
    JOIN   dbo.DimProduct AS p  ON p.ProductKey = f.ProductKey
    JOIN   tdw.Produit    AS pr ON pr.ProductAlternateKey = p.ProductAlternateKey
    JOIN   dbo.DimDate    AS d  ON d.DateKey = f.OrderDateKey
    GROUP BY pr.ProduitKey, d.CalendarYear, d.MonthNumberOfYear
)
SELECT COALESCE(r.ProduitKey, i.ProduitKey) AS ProduitKey,
       pr.NomProduit,
       COALESCE(r.Annee, i.Annee)           AS Annee,
       COALESCE(r.Mois,  i.Mois)            AS Mois,
       ISNULL(r.CARevendeurs, 0)            AS CARevendeurs,
       ISNULL(i.CAInternet,   0)            AS CAInternet
INTO   #R8
FROM   Revendeurs AS r
FULL OUTER JOIN Internet AS i
       ON  i.ProduitKey = r.ProduitKey AND i.Annee = r.Annee AND i.Mois = r.Mois
JOIN   tdw.Produit AS pr ON pr.ProduitKey = COALESCE(r.ProduitKey, i.ProduitKey);

SELECT * FROM #R8 ORDER BY Annee, Mois, ProduitKey;

/* R8 — contrôle : totaux conservés et répartition des cellules */
SELECT COUNT(*)                                               AS NbCellules,
       SUM(CASE WHEN CARevendeurs > 0 AND CAInternet > 0 THEN 1 ELSE 0 END) AS CellulesCommunes,
       SUM(CASE WHEN CAInternet = 0 THEN 1 ELSE 0 END)        AS RevendeursSeuls,
       SUM(CASE WHEN CARevendeurs = 0 THEN 1 ELSE 0 END)      AS InternetSeul,
       SUM(CARevendeurs)                                      AS TotalRevendeurs,
       (SELECT SUM(SalesAmount) FROM dbo.FactResellerSales)   AS TotalSourceRevendeurs,
       SUM(CAInternet)                                        AS TotalInternet,
       (SELECT SUM(SalesAmount) FROM dbo.FactInternetSales)   AS TotalSourceInternet
FROM   #R8;

DROP TABLE #R8;
GO

/* #####################################################################
   BONUS (facultatif) — B1 et B2

   Attention : contrairement au reste de ce fichier, cette partie ÉCRIT,
   mais uniquement dans un schéma séparé « bonus » ; les tables des
   schémas dbo, tdw et tdw_scd2 ne sont jamais modifiées. Elle est
   réexécutable : chaque partie supprime d'abord ce qu'elle a créé.

   B1 — ProduitPrix en table temporelle système (SYSTEM_VERSIONING = ON)
        et pourquoi le temps système ne remplace pas le temps de validité.
   B2 — Changement de prix mensuel sur 10 produits pendant 24 mois :
        nombre de lignes créées dans le modèle TDW et dans le modèle SCD 2.
   ##################################################################### */

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
