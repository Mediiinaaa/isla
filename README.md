# Isla

Una isla para el notch de tu Mac, inspirada en la Dynamic Island del iPhone. Gratis y de código abierto.

## Qué hace

- **Música**: canción actual de Spotify o Música con carátula, controles y gestos (desliza con dos dedos para cambiar de canción)
- **Volumen y brillo**: sustituye los avisos de macOS por unos en la isla
- **Batería**: avisa al conectar o desconectar el cargador, con batería baja y en modo de ahorro
- **Calendario**: próximos eventos y recordatorios, con enlace directo a Zoom, Meet, Teams o Webex
- **Otros**: cambio de auriculares o altavoz, sonido cada hora, mantener el Mac despierto
- Funciona también en Macs sin notch (notch simulado)

Requiere macOS 14 Sonoma o posterior. Funciona en Macs con Apple Silicon y con Intel.

## Instalar

1. Descarga **Isla.zip** desde la [última versión](../../releases/latest).
2. Descomprímelo y arrastra **Isla.app** a la carpeta **Aplicaciones**.
3. Ábrela. Como la app no está firmada por Apple, macOS la bloqueará la primera vez:
   - Ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el final y pulsa **Abrir igualmente**.
   - O, en Terminal: `xattr -dr com.apple.quarantine /Applications/Isla.app`

Isla vive en la barra de menús (no sale en el Dock). Desde ahí abres los ajustes.

### Permisos

Según lo que actives, Isla te pedirá:

- **Accesibilidad**: para sustituir los avisos de volumen y brillo
- **Automatización**: para controlar Spotify y Música
- **Calendarios**: para mostrar tus eventos (no salen de tu Mac)

<sub>Parte de este proyecto se ha hecho con ayuda de Claude (Anthropic).</sub>

## Compilar desde el código

Necesitas Xcode o las Command Line Tools.

```sh
./build.sh     # compila e instala en /Applications
./release.sh   # crea dist/Isla.zip (Apple Silicon + Intel)
```

## Aviso

Isla es un proyecto personal sin relación con Apple ni Spotify. "Dynamic Island", Mac y macOS son marcas de Apple Inc.

## Licencia

[MIT](LICENSE). Hecho por Mediiinaaa.
