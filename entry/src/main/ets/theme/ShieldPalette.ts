export interface ShieldColors {
  canvas: string;
  canvasEnd: string;
  card: string;
  soft: string;
  border: string;
  accent: string;
  selected: string;
  action: string;
  sidebar: string;
}

export interface ShieldPalette {
  id: string;
  en: string;
  zh: string;
  hant: string;
  swatches: string[];
  light: ShieldColors;
  dark: ShieldColors;
}

export const DEFAULT_SHIELD_PALETTE = 'default';

export function paletteAlpha(color: string, alpha: string): string {
  return '#' + alpha + color.substring(1);
}

function mix(base: string, tint: string, ratio: number): string {
  let color = '#';
  for (let index = 1; index <= 5; index += 2) {
    const from = parseInt(base.substring(index, index + 2), 16);
    const to = parseInt(tint.substring(index, index + 2), 16);
    color += Math.round(from + (to - from) * ratio).toString(16).padStart(2, '0');
  }
  return color.toUpperCase();
}

function createPalette(id: string, en: string, zh: string, hant: string, seed: string,
  first: string, last: string, paper: string): ShieldPalette {
  const action = mix(seed, '#161B26', 0.16);
  const lightCard = mix('#FFFFFF', paper, 0.82);
  const darkCard = mix('#1D2330', seed, 0.15);
  return {
    id, en, zh, hant, swatches: [first, last],
    light: {
      canvas: mix('#F5F6FA', first, 0.34),
      canvasEnd: mix('#F5F6FA', last, 0.27),
      card: lightCard,
      soft: mix(lightCard, first, 0.19),
      border: mix(lightCard, seed, 0.14),
      accent: action,
      selected: mix(lightCard, seed, 0.12),
      action,
      sidebar: mix(lightCard, last, 0.15),
    },
    dark: {
      canvas: mix('#131823', seed, 0.16),
      canvasEnd: mix('#131823', last, 0.09),
      card: darkCard,
      soft: mix(darkCard, first, 0.10),
      border: mix(darkCard, first, 0.20),
      accent: mix(first, '#FFFFFF', 0.39),
      selected: mix(darkCard, seed, 0.34),
      action,
      sidebar: mix(darkCard, last, 0.06),
    },
  };
}

export const SHIELD_PALETTES: ShieldPalette[] = [
  {
    id: DEFAULT_SHIELD_PALETTE,
    en: 'Default blue',
    zh: '默认蓝',
    hant: '預設藍',
    swatches: ['#C9D5FF', '#EDF3FF'],
    light: {
      canvas: '#F2F5FC', canvasEnd: '#F2F5FC', card: '#FFFFFF', soft: '#F2F4F8', border: '#E1E7F2',
      accent: '#354DD1', selected: '#E8EDFF', action: '#4058DD', sidebar: '#F9FAFF',
    },
    dark: {
      canvas: '#131A2C', canvasEnd: '#131A2C', card: '#1C263E', soft: '#212C40', border: '#303B55',
      accent: '#B5C4FF', selected: '#2B3A68', action: '#4058DD', sidebar: '#171F34',
    },
  },
  createPalette('aurora', 'Aurora Glow', '极光霓彩', '極光霓彩', '#5B54C4', '#BA9BF9', '#55DAE9', '#FAFBFF'),
  createPalette('teal', 'Sea Salt Mint', '海盐薄荷', '海鹽薄荷', '#2C766C', '#AEDFD5', '#D2EFE8', '#F7FDFB'),
  createPalette('orchidpeach', 'Orchid Peach', '藕霞蜜桃', '藕霞蜜桃', '#995480', '#D0A7CF', '#FFE4D9', '#FFFAFC'),
  createPalette('icedorange', 'Iced Orange', '冰镇橘光', '冰鎮橘光', '#9E5A2B', '#FFC097', '#C8F7FE', '#FFFCF9'),
  createPalette('slate', 'Misty Slate', '雾岚青灰', '霧嵐青灰', '#586D7F', '#BBCAD7', '#E0E8EF', '#FAFBFC'),
];

export function shieldPalette(id: string): ShieldPalette {
  return SHIELD_PALETTES.find((palette: ShieldPalette) => palette.id === id) ?? SHIELD_PALETTES[0];
}
