-- B1. Produits ayant plusieurs versions et leur historique de prix 
SELECT ProductAlternateKey, ProductKey, ListPrice, StartDate, EndDate, Status 
FROM   dbo.DimProduct 
WHERE  ProductAlternateKey IN (SELECT ProductAlternateKey 
                               FROM   dbo.DimProduct 
                               GROUP BY ProductAlternateKey 
                               HAVING COUNT(*) > 1) 
ORDER BY ProductAlternateKey, StartDate; 

-- B2. Employés ayant plusieurs versions 
SELECT EmployeeNationalIDAlternateKey, COUNT(*) AS NbVersions 
FROM   dbo.DimEmployee 
GROUP BY EmployeeNationalIDAlternateKey 
HAVING COUNT(*) > 1; 

-- B3. Période couverte par les ventes aux revendeurs 
SELECT MIN(d.FullDateAlternateKey) AS PremiereVente, 
       MAX(d.FullDateAlternateKey) AS DerniereVente 
FROM   dbo.FactResellerSales AS f 
JOIN   dbo.DimDate AS d ON d.DateKey = f.OrderDateKey;

-- B4. Contrainte de synchronisation (p. 128) : combien de ventes tombent
--     en dehors de la période de validité de la version de produit vendue ? 
SELECT COUNT(*) AS NbVentesHorsValidite 
FROM   dbo.FactResellerSales AS f 
JOIN   dbo.DimDate    AS d ON d.DateKey = f.OrderDateKey 
JOIN   dbo.DimProduct AS p ON p.ProductKey = f.ProductKey 
WHERE  d.FullDateAlternateKey <  CAST(p.StartDate AS DATE) 
   OR  d.FullDateAlternateKey >  ISNULL(CAST(p.EndDate AS DATE), '9999-12-31');
