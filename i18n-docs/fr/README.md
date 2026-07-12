# Coffre-fort Mac

Mac Vault est le membre natif macOS de la famille de produits Vault. Il combine un moteur de stratégie Swift, un éditeur WebView, un inventaire d'applications natif et des adaptateurs d'application, une prise en charge de règles personnalisées et un hub de pont d'application Web local.

Le code actuel est la source de la vérité. La référence en anglais dans l'application est [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Ce qui est implémenté

- Groupes par défaut pour les applications macOS sélectionnées et groupes personnalisés pour les règles de politique avancées.
- Modes de blocage immédiat, d'allocation et de compte à rebours.
- Planifications, modes de gel, flux de répétition, importation/exportation et état de groupe persistant.
- Inventaire des applications, état des autorisations de contrôle des appareils, adaptateurs d'application natifs et surface d'état flottante.
- Un environnement d'exécution de politique JavaScript contrôlé avec journalisation et vérification de la syntaxe.
- Un hub de pont WebSocket de bouclage pour les groupes compatibles explicitement liés.
- Un éditeur WebView avec le même modèle de groupe central que la famille de produits Vault.

## Développement

Exécutez les tests du package Swift :

```bash
swift test
```

Le package comprend des tests de stratégie de base, de planification, de règles personnalisées, de pont, d'importation et de contrôle macOS.

## Projet Xcode

Le projet Xcode facultatif est généré à partir de [XcodeProject/project.yml](XcodeProject/project.yml) :

```bash
cd XcodeProject
./generate.sh
```

Lisez [XcodeProject/README.md](XcodeProject/README.md) avant de configurer les cibles de signature ou de distribution.

## Politique de documentation

Les documents anglais restent canoniques. L'interface utilisateur de l'éditeur dispose de catalogues régionaux complets, de manuels traduits en direct à côté de `WebAssets/manual/en.md` et des copies traduites des documents conservés restants se trouvent sous `i18n-docs/<locale>/`.

Les conditions juridiques et les avis de confidentialité restent des documents juridiques distincts ; ce README ne les remplace pas.
