# Serveurs locaux

Une petite app de la barre de menus macOS : l’icône indique combien de serveurs de dev tournent ; son menu (natif, comme celui de Docker) liste chaque serveur — projet, type, port, depuis quand — avec un sous-menu pour l’ouvrir, l’afficher dans le Finder, copier son PID ou l’arrêter.

- **Native et légère** : AppKit, aucune dépendance, moins de 100 Mo de RAM, quasi 0 % de CPU. Lecture des ports toutes les 3 s quand le menu est ouvert, toutes les 30 s sinon (pour le compteur de l’icône).
- **Rien ne s’arrête tout seul** : chaque arrêt demande une confirmation ; SIGKILL n’est proposé que si SIGTERM n’a pas suffi après 5 s.
- Pas de Dock, pas de fenêtre : juste l’icône (avec le nombre de serveurs). L’arrêt passe par une alerte macOS de confirmation.

## Installer (ce Mac, ou un autre)

```sh
git clone https://github.com/julienLeMee/serveurs-locaux.git
cd serveurs-locaux
./build.sh
```

Le script compile l’app (Apple Silicon + Intel), l’installe dans `~/Applications/Serveurs locaux.app` et la lance. Il faut seulement les outils Apple (`xcode-select --install`, déjà là si `git` marche). Relancer `./build.sh` après un `git pull` pour mettre à jour.

Pour qu’elle démarre avec le Mac : menu de l’icône → **Ouvrir à la connexion**.

Sans outils Apple, on peut aussi copier `~/Applications/Serveurs locaux.app` d’un Mac à l’autre. L’app n’étant pas notariée, macOS la bloque au premier lancement : Réglages Système → Confidentialité et sécurité → **Ouvrir quand même**.

## Ce que le menu montre

- **Un lancement = une ligne** : `pnpm dev → cross-env → next dev → next-server` est regroupé ; « Arrêter » vise tout le groupe.
- **Origine** : terminal de l’app Claude, session Claude Code, terminal de Cursor / VS Code, Terminal, iTerm2, Warp, tmux… avec le tty ; « Arrière-plan » pour un serveur lancé avec `&` / `nohup`.
- **Docker** : le conteneur (et son projet compose) plutôt que le moteur Docker ; « Arrêter » fait `docker stop`, puis `docker kill` si besoin.
- **Projets multi-sites** : si le projet a une collection Payload `Tenants` (`src/collections/Tenants.ts`) et une base Postgres dans Docker, ses sites `<slug>.localhost` sont listés dans un sous-menu « Sites » (lus via `docker exec … psql`, mis en cache 1 min).
- Seuls les serveurs de dev sont montrés : les applications et services de macOS qui ouvrent aussi un port (AirPlay, Spotify, Notion…) sont ignorés.

## En ligne de commande

```sh
"$HOME/Applications/Serveurs locaux.app/Contents/MacOS/ServeursLocaux" --list
"$HOME/Applications/Serveurs locaux.app/Contents/MacOS/ServeursLocaux" --stop 3000           # SIGTERM
"$HOME/Applications/Serveurs locaux.app/Contents/MacOS/ServeursLocaux" --stop 3000 --force   # SIGKILL
```
