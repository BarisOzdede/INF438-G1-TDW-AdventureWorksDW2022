# Entrepôt de données temporel sur AdventureWorksDW — INF438, groupe 1

Mise en œuvre et évaluation du modèle de l'article :

> W. Ahmed, E. Zimányi, A. A. Vaisman, R. Wrembel, *A Temporal Multidimensional Model and OLAP Operators*,
> International Journal of Data Warehousing and Mining, 16(4), 2020, p. 112–143. DOI : 10.4018/IJDWM.2020100107

**Question de recherche.** Le modèle temporel de l'article (TDW), appliqué à AdventureWorksDW, répond-il
correctement et plus simplement aux requêtes temporelles que la structure SCD de type 2 déjà présente
dans AdventureWorksDW ?

Le dépôt construit deux modèles côte à côte, sans jamais modifier le schéma `dbo` :

- **`tdw`** — le modèle de l'article (Figure 16) : clés de substitution **stables**, une table par
  attribut temporel et par relation temporelle, intervalles semi-ouverts `[FromDate, ToDate)` ;
- **`tdw_scd2`** — une copie réduite de la structure SCD 2 d'AdventureWorksDW (une clé par **version**).

Le même scénario de changements (`04_scenario.sql`, fourni) est appliqué aux deux modèles, puis les
mêmes requêtes y sont écrites et comparées.

---

## Environnements testés

Les scripts ont été exécutés de bout en bout dans deux environnements ; **tous les résultats sont
identiques** (nombres de lignes, sommes, dates du scénario, résultats de R1 à R5, tests).

| | Environnement 1 | Environnement 2 |
|---|---|---|
| Moteur | SQL Server 2022 RTM (16.0.1000.6) | Azure SQL Edge Developer 15.0.2000.1574 (moteur SQL Server 2019, ARM64) |
| Système | Windows, SSMS | macOS (Docker), VS Code + `sqlcmd` |
| Base | AdventureWorksDW2022 | AdventureWorksDW2019 |

**Compatibilité.** SQL Server 2016 ou plus récent (`DROP ... IF EXISTS`, `CREATE OR ALTER`,
`DATEDIFF_BIG`). Aucune fonction propre à SQL Server 2022 n'est utilisée : `GREATEST` / `LEAST` sont
remplacées par `dbo.MaxDate` / `dbo.MinDate` (définies dans `05_requetes.sql`).

**Les scripts ne contiennent pas d'instruction `USE`** : sélectionnez la base AdventureWorksDW avant de
les exécuter (liste déroulante dans SSMS / VS Code, ou option `-d` de `sqlcmd`).

---

## Ordre d'exécution

Sur une copie neuve d'AdventureWorksDW, exécuter dans l'ordre :

| Fichier | Étape | Contenu | Modifie les données ? |
|---|---|---|---|
| `01_inventaire.sql` | B | Requêtes B1 à B4 (historique SCD 2 existant) | non |
| `02_schema.sql` | C | Schémas `tdw` et `tdw_scd2`, tables, contraintes, déclencheurs anti-chevauchement (bonus) | crée les tables |
| `03_chargement.sql` | C | Chargement initial (C2), table de faits sur clés stables (C3), copies SCD 2 (C4) | charge les tables |
| `04_scenario.sql` | D | Scénario fourni, **non modifié** — **une seule fois** | applique les 4 événements |
| `05_requetes.sql` | E | R1, R2, R3 (TDW et SCD 2), R4, R5 (TDW) ; bonus R6, R7, R8, B1, B2 | non pour `dbo`, `tdw`, `tdw_scd2` (crée `dbo.MaxDate`, `dbo.MinDate` ; B1/B2 écrivent uniquement dans le schéma `bonus`) |
| `06_mesures.sql` | F2 | Temps d'exécution de R1 à R3, sans puis avec index | non (crée des index) |
| `07_tests.sql` | F1 | Tests de validation 1 à 5 | non |

`05`, `06` et `07` sont indépendants entre eux (seuls `02` → `03` → `04` sont requis avant).

**Rejouer le scénario.** `04_scenario.sql` refuse de s'exécuter deux fois. Relancer `02` (qui supprime
tout, y compris `tdw.ScenarioJournal`), puis `03` et `04`.

**Exécution en ligne de commande** (exemple ; le mot de passe est passé par variable d'environnement) :

```bash
export SQLCMDPASSWORD='...'
for f in 01_inventaire 02_schema 03_chargement 04_scenario 05_requetes 06_mesures 07_tests; do
  sqlcmd -S localhost -U sa -C -d AdventureWorksDW2019 -i $f.sql -o sonuclar/$f.txt -W -s"|"
done
```

Le dossier `sonuclar/` (sorties locales) est exclu du dépôt par `.gitignore`.

---

## Résultats attendus

### Chargement (`03`)

| Table | Lignes | | Table | Lignes |
|---|---|---|---|---|
| `tdw.Produit` | 504 | | `tdw.Employe` | 290 |
| `tdw.ProduitDureeVie` | 504 | | `tdw.EmployeSupervision` | 289 |
| `tdw.ProduitPrix` | 293 | | `tdw.EmployeTerritoire` | 290 |
| `tdw.ProduitSousCategorie` | 295 | | `tdw.Ventes` | 60 855 |
| `tdw.SousCategorieNom` | 37 | | `tdw_scd2.DimProduit` | 606 |
| | | | `tdw_scd2.Ventes` | 60 855 |

Contrôle C3 : `tdw.Ventes` et `dbo.FactResellerSales` ont 60 855 lignes et la même somme
(80 450 596,9823).

### Scénario (`04`)

| Événement | Date | Effet |
|---|---|---|
| 1 | 2012-02-01 | LJ-0192-L, -M, -XL (Long-Sleeve Logo Jersey) passent de Jerseys à Vests ; SCD 2 : 1 742 lignes de faits réaffectées |
| 2 | 2012-06-01 | +8 % sur le prix des 97 produits de la catégorie Bikes |
| 3 | 2012-08-01 | Sous-catégorie 25 : « Vests » → « Vests and Jackets » (TDW uniquement) |
| 4 | 2012-09-01 | Linda Mitchell change de superviseur : Stephen Jiang → Brian Welcker |

**Coût du premier événement** : 6 lignes dans le modèle TDW (3 clôtures + 3 insertions dans
`ProduitSousCategorie`) contre 1 748 dans le modèle SCD 2 (3 versions + 3 clôtures dans `DimProduit`,
1 742 ventes réaffectées).

### Requêtes (`05`)

**R1 (temporellement cohérent) et R2 (time-slice « maintenant »)** ne diffèrent que pour Jerseys (21)
et Vests (25), avant @t1 — l'équivalent des Figures 13 et 14 de l'article :

| Année | R1 Jerseys | R1 Vests | R2 Jerseys | R2 Vests |
|---|---|---|---|---|
| 2010 | 2 422,59 | — | — | 2 422,59 |
| 2011 | 66 013,37 | — | — | 66 013,37 |
| 2012 | 41 706,75 | 135 001,81 | 21 780,49 | 154 928,06 |
| 2013 | 213 249,76 | 344 715,80 | 213 249,76 | 344 715,80 |

R1, R2 et R3 donnent exactement le même résultat dans les modèles TDW et SCD 2 (test 5).

**R4** : 17 vendeurs ; en tête, Linda Mitchell (7 981 815,49).

**R5** — chiffre d'affaires personnel des superviseurs pendant leurs périodes de supervision :

| Superviseur | Avec coalescing | Sans coalescing | Facteur |
|---|---|---|---|
| Stephen Jiang | 1 092 123,86 | 10 311 565,48 | ≈ 9,4 |
| Amy Alberts | 732 078,44 | 2 196 235,33 | 3 |
| Syed Abbas | 172 524,45 | 172 524,45 | 1 |

Sans coalescing, chaque vente d'un superviseur est comptée autant de fois qu'il a de subordonnés.

### Mesures (`06`) — médiane de 3 exécutions, en ms

| Requête | TDW | SCD 2 | Avec index (TDW / SCD 2) |
|---|---|---|---|
| R1 | 36,7 | 26,7 | 36,7 / 26,7 |
| R2 | 26,7 | 33,3 | 26,7 / 33,3 |
| R3 | 10,0 | 16,7 | 10,0 / 16,7 |

Valeurs indicatives (environnement 2 ; résolution de l'horloge ≈ 3,3 ms). L'index ne change rien à
cette échelle : les clés primaires `(clé du membre, FromDate)` sont déjà des index cluster et les
tables temporelles sont petites.

### Tests (`07`)

Une requête par test : le test 1 renvoie une égalité vérifiée (`OK`), les tests 2, 3, 4, 5a, 5b et 5c
renvoient **zéro ligne**. Tests : 1 (faits identiques à la source), 2 (aucun chevauchement),
3 (synchronisation), 4 (somme annuelle de R1 = CA de l'année), 5a, 5b, 5c (R1, R2, R3 identiques dans
les deux modèles, EXCEPT dans les deux sens). Le récapitulatif final affiche 7 × OK.
Contrôle de sens : R1 et R2 diffèrent sur exactement 4 lignes.

### Bonus (`05`)

- **R6** : 9 produits, 12 périodes avant coalescing, 9 après ; total inchangé (803 110,08).
- **R7** (2012) : le sommet de la hiérarchie (Ken Sánchez, Brian Welcker) cumule exactement le CA de
  l'année (28 193 631,53).
- **R8** : 3 857 cellules (produit × mois), dont 1 526 communes aux deux canaux ; totaux conservés.
- **B1** : la modification de prix est datée du moment de l'`UPDATE`, pas du 2012-06-01 ;
  `FOR SYSTEM_TIME AS OF '2012-07-01'` renvoie 0 ligne (TDW : 293) ; les colonnes de période sont en
  lecture seule (erreur 13537). Le temps système est un temps de transaction, pas un temps de validité.
- **B2** (10 produits × 24 mois) : 240 lignes insérées et 240 modifiées dans les deux modèles, mais
  52 octets par ligne en TDW contre 125 dans la copie SCD 2 réduite et ≈ 10 ko dans `dbo.DimProduct`
  complète ; en SCD 2, c'est la table de dimension elle-même qui grossit (609 → 849 lignes).

---

## Choix de conception

- **Clé stable (C3).** Dans AdventureWorksDW, `ProductKey` et `EmployeeKey` identifient une *version*.
  Les clés `ProduitKey` et `EmployeKey` identifient le *membre* ; le passage version → membre se fait
  par la clé métier (`ProductAlternateKey`, `EmployeeNationalIDAlternateKey`).
- **Intervalles.** Modèle TDW : semi-ouverts `[FromDate, ToDate)`, intervalle ouvert = `9999-12-31`.
  AdventureWorksDW et la copie SCD 2 : intervalles fermés `[StartDate, EndDate]`, `EndDate` NULL pour la
  version courante ; les requêtes SCD 2 en tiennent compte.
- **État initial (C2).** Une ligne par membre sur `[1900-01-01, 9999-12-31)`, valeurs de la version
  courante (à défaut, la plus récente). Une valeur non définie (prix ou sous-catégorie NULL, pas de
  superviseur) ne crée pas de ligne.
- **Superviseurs.** Retrouvés par auto-jointure sur `ParentEmployeeKey`, la colonne
  `ParentEmployeeNationalIDAlternateKey` étant vide (vérifié sur AdventureWorksDW2022).
- **R2 / R3 en SCD 2.** Version courante = `EndDate IS NULL`, à défaut la plus récente (même règle que
  C2) ; version à une date = celle dont l'intervalle fermé contient la date, à défaut la plus ancienne.
  Sans ces règles, les ventes des produits sans version courante disparaîtraient du résultat.
  La règle de repli de R3 s'applique à la plupart des produits : les intervalles de `dbo.DimProduct`
  sont incohérents (`StartDate` décalées mais pas `EndDate`, d'où `EndDate < StartDate` ; requête B4 :
  48 954 ventes sur 60 855 hors de la validité de leur version).
- **Comparaison des modèles.** Regroupement par `ProductSubcategoryKey` et non par le nom (le
  renommage de @t3 n'existe que dans le modèle TDW).
- **Coalescing** (absent de l'article). Fonctions de fenêtrage : une période ouvre un nouveau groupe si
  elle commence après la fin la plus tardive des périodes précédentes ; chaque groupe est fusionné en
  `[MIN(FromDate), MAX(ToDate))`.
- **R7.** `FULL OUTER JOIN` entre ventes personnelles et ventes des subordonnés, pour ne pas perdre les
  managers sans ventes personnelles.
- **Index (`06`).** Les index créés restent en place ; le script les supprime au début, il est donc
  réexécutable.
