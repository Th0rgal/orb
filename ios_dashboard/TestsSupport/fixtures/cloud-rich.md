# Rendement annualisé

Le calcul est **composé**, avant frais. La formule est \(r = (V_f/V_i)^{1/n} - 1\), soit $2x+1$ dans cet exemple simplifié.

$$
\begin{aligned}
r &= \left(\frac{V_f}{V_i}\right)^{1/n}-1 \\
\sigma &= \sqrt{\frac{1}{N}\sum_{i=1}^{N}(x_i-\bar{x})^2}
\end{aligned}
$$

| Période | Euros | Dollars | Note |
| --- | ---: | ---: | --- |
| Départ | 243 € | 287 $ | |
| Arrivée | 3 767 € | 4 296 $ | exemple \| illustration |

Le prix de $15 et celui de $20 sont des montants, pas des formules.

- Hypothèses
  - **Dates identiques** pour les deux devises
  - Résultats avant frais
1. Lire les valeurs initiales.
2. Calculer le rendement.

> Une moyenne annualisée ne garantit pas un rendement annuel constant.

```python
rate = (final / initial) ** (1 / years) - 1
print("$not_math$", rate)
```

[Source de référence](https://www.ecb.europa.eu/)

![Graphique généré](sandbox:/mnt/data/chart.png)

[Télécharger les données](sandbox:/mnt/data/result.csv)

Fin de la réponse — RICH_RESPONSE_END.
