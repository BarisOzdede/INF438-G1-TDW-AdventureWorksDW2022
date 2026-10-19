/* =====================================================================
   05_requetes.sql  —  Étape E : requêtes R1 à R5

   À exécuter après 02 → 03 → 04 (le scénario doit avoir été joué :
   les dates @t1..@t4 sont lues dans tdw.ScenarioJournal).

   R1, R2, R3 : modèles TDW et SCD 2   (comparés dans 07_tests.sql)
   R4, R5     : modèle TDW uniquement

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
   - aucune version valide à @veille (produit créé après, ou trou dans
     l'historique) : on retient la version la plus ancienne, c'est-à-dire
     l'état connu le plus proche, ce qui correspond à l'hypothèse C2 du
     modèle TDW (état initial supposé valide depuis 1900) ;
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
