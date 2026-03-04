-----------------------------------------------------
-- 1. Création de la base de données
-----------------------------------------------------

CREATE DATABASE olist_churn;
GO

USE olist_churn;
GO

-----------------------------------------------------
-- 2. Création des schémas
-- staging : tables brutes importées
-- bi : vues analytiques utilisées pour l'analyse
-----------------------------------------------------

CREATE SCHEMA staging;
GO

CREATE SCHEMA bi;
GO

-----------------------------------------------------
-- 3. Vérification des tables importées
-----------------------------------------------------

SELECT 
  s.name AS schema_name,
  t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.name LIKE '%order%item%'
ORDER BY s.name, t.name;

-----------------------------------------------------
-- 4. Correction des types de données
-- Conversion des montants en format DECIMAL
-- pour faciliter les calculs financiers
-----------------------------------------------------

ALTER TABLE staging.olist_order_items_dataset
ALTER COLUMN price DECIMAL(10,2);

ALTER TABLE staging.olist_order_items_dataset
ALTER COLUMN freight_value DECIMAL(10,2);

ALTER TABLE staging.olist_order_payments_dataset
ALTER COLUMN payment_value DECIMAL(10,2);

-----------------------------------------------------
-- Vérification rapide des données
-----------------------------------------------------

SELECT TOP 20 *
FROM staging.olist_order_payments_dataset;

SELECT COUNT(*) 
FROM staging.olist_orders_dataset;

-----------------------------------------------------
-- 5. Calcul du revenu par commande
-- Somme du prix produit + frais de livraison
-----------------------------------------------------

CREATE OR ALTER VIEW bi.v_revenu_par_commande AS
SELECT 
    oi.order_id,
    SUM(oi.price + oi.freight_value) AS revenu_commande
FROM staging.olist_order_items_dataset oi
GROUP BY oi.order_id;
GO

-----------------------------------------------------
-- Vérification de la vue
-----------------------------------------------------

SELECT TOP 10 *
FROM bi.v_revenu_par_commande;

-----------------------------------------------------
-- 6. Création d'une vue enrichie des commandes
-- Ajout du revenu à chaque commande
-- Filtrage sur les commandes livrées
-----------------------------------------------------

CREATE OR ALTER VIEW bi.v_commandes_enrichies AS
SELECT 
    o.order_id,
    o.customer_id,
    o.order_status,
    o.order_purchase_timestamp,
    r.revenu_commande
FROM staging.olist_orders_dataset o
LEFT JOIN bi.v_revenu_par_commande r
    ON o.order_id = r.order_id
WHERE LOWER(LTRIM(RTRIM(CAST(o.order_status AS NVARCHAR(50))))) = 'delivered';
GO

-----------------------------------------------------
-- Vérification de la vue enrichie
-----------------------------------------------------

SELECT TOP 10 *
FROM bi.v_commandes_enrichies;

-----------------------------------------------------
-- Vérification du nombre total de commandes
-----------------------------------------------------

SELECT COUNT(*) AS nb_lignes_orders
FROM staging.olist_orders_dataset;

-----------------------------------------------------
-- 7. Calcul du churn client
-- Un client est considéré churn si
-- aucun achat n'a été réalisé depuis 90 jours
-----------------------------------------------------

CREATE OR ALTER VIEW bi.v_churn_clients_90j AS

WITH commandes_u AS (
    SELECT
        c.customer_unique_id,
        e.order_purchase_timestamp
    FROM bi.v_commandes_enrichies e
    JOIN staging.olist_customers_dataset c
      ON e.customer_id = c.customer_id
),

-----------------------------------------------------
-- Date de référence : dernière date d'achat
-- dans le dataset
-----------------------------------------------------

date_ref AS (
    SELECT MAX(order_purchase_timestamp) AS date_reference
    FROM bi.v_commandes_enrichies
),

-----------------------------------------------------
-- Dernier achat par client
-----------------------------------------------------

derniere AS (
    SELECT
        customer_unique_id,
        MAX(order_purchase_timestamp) AS derniere_achat
    FROM commandes_u
    GROUP BY customer_unique_id
)

-----------------------------------------------------
-- Calcul de l'indicateur churn
-----------------------------------------------------

SELECT
    d.customer_unique_id,
    d.derniere_achat,
    CASE 
        WHEN DATEDIFF(DAY, d.derniere_achat, r.date_reference) > 90 THEN 1
        ELSE 0
    END AS est_churn_90j
FROM derniere d
CROSS JOIN date_ref r;
GO

-----------------------------------------------------
-- 8. Calcul des indicateurs churn
-----------------------------------------------------

SELECT 
  COUNT(*) AS total_clients,
  SUM(est_churn_90j) AS nb_churn,
  AVG(CAST(est_churn_90j AS FLOAT)) AS taux_churn
FROM bi.v_churn_clients_90j;