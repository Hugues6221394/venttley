/// Calm, easy-to-read wordlist for Venttly's 12-word recovery phrase.
///
/// 128 distinct words → a 12-word phrase carries ~84 bits of entropy, which is
/// infeasible to brute-force even though the encrypted recovery blob is
/// readable pre-auth. Words are gentle and on-brand so the phrase feels like
/// part of the experience rather than a scary crypto string.
library;

const List<String> kRecoveryWordlist = [
  'river', 'mango', 'shadow', 'candle', 'moonlight', 'velvet', 'willow', 'ember',
  'harbor', 'meadow', 'lantern', 'pebble', 'cedar', 'dawn', 'feather', 'garden',
  'honey', 'ivory', 'jasmine', 'ladder', 'maple', 'nectar', 'olive', 'petal',
  'quartz', 'ripple', 'saffron', 'thistle', 'amber', 'violet', 'walnut', 'breeze',
  'cocoa', 'echo', 'fern', 'glade', 'haven', 'indigo', 'juniper', 'linen',
  'marble', 'orchard', 'pillow', 'quiet', 'robin', 'sparrow', 'tulip', 'acorn',
  'birch', 'clover', 'daisy', 'forest', 'grove', 'hazel', 'island', 'jade',
  'kettle', 'lemon', 'mist', 'ocean', 'prairie', 'quill', 'rainfall', 'sunset',
  'timber', 'valley', 'wheat', 'yarn', 'zephyr', 'apricot', 'blossom', 'cinder',
  'evening', 'firefly', 'gentle', 'hollow', 'lullaby', 'lilac', 'mellow', 'noble',
  'opal', 'plum', 'rosemary', 'silk', 'vine', 'whisper', 'azure', 'basil',
  'cobble', 'dusk', 'embrace', 'galaxy', 'harmony', 'lagoon', 'mantle', 'nimbus',
  'pasture', 'quiver', 'radiance', 'solace', 'twilight', 'umber', 'vapor', 'wander',
  'yearn', 'aura', 'bramble', 'coral', 'drizzle', 'flicker', 'glimmer', 'horizon',
  'kindle', 'murmur', 'nestle', 'ponder', 'ridge', 'serene', 'tender', 'unfold',
  'vessel', 'woven', 'yonder', 'almond', 'beacon', 'comet', 'dapple', 'eden',
];
