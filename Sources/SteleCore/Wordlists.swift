/// Curated word pools used to build slugs.
///
/// Slugs read as `adjective-nature-creature`, e.g. `quiet-cedar-otter`. Keeping each
/// slot to its own part of speech is what makes every combination land as a phrase
/// rather than as three words that happen to be adjacent.
///
/// Rules for anything added here:
///   - concrete, picturable, and pronounceable on the first try
///   - neutral in tone; nothing violent, medical, political, or bodily
///   - safe next to *every* word in the neighbouring pools, since all combinations occur
///   - lowercase ASCII letters only (`Slug.isValid` rejects anything else)
public enum Wordlists {
    /// Slot one. Attributive nouns (`summer`, `granite`) are welcome — they read as
    /// adjectives in this position.
    public static let adjectives: [String] = [
        "amber", "ancient", "arctic", "ashen", "autumn", "azure", "balmy", "blazing",
        "bold", "boreal", "brave", "breezy", "briny", "bright", "brisk", "bronze",
        "bubbly", "buoyant", "calm", "candid", "carefree", "cerulean", "cheerful", "chilly",
        "civic", "classic", "clear", "clever", "cloudy", "coastal", "cobalt", "cosmic",
        "cozy", "crimson", "crisp", "crystal", "curious", "dainty", "dapper", "daring",
        "dawnlit", "deep", "delicate", "dewy", "diligent", "distant", "downy", "dreamy",
        "dusky", "dusty", "eager", "earnest", "earthy", "eastern", "elder", "electric",
        "elegant", "emerald", "endless", "fabled", "faded", "fair", "fancy", "feathered",
        "ferny", "fertile", "fiery", "fleet", "floating", "fluent", "fluffy", "fond",
        "forested", "fragrant", "free", "fresh", "frosty", "gallant", "gentle", "giddy",
        "gilded", "glad", "glassy", "gleaming", "gliding", "glowing", "golden", "graceful",
        "grand", "granite", "grassy", "hallowed", "hardy", "harmonic", "hazel", "hazy",
        "hearty", "hidden", "high", "hollow", "honest", "humble", "idle", "indigo",
        "inland", "ivory", "jade", "jolly", "jovial", "joyful", "keen", "kindly",
        "lacy", "lambent", "languid", "lively", "lofty", "lone", "lucid", "lucky",
        "lunar", "lush", "mellow", "merry", "midnight", "mighty", "mild", "milky",
        "mindful", "minted", "misty", "modest", "mossy", "mottled", "muted", "narrow",
        "native", "nautical", "neat", "nimble", "noble", "northern", "olive", "opal",
        "open", "orchard", "ornate", "pastel", "patient", "peaceful", "pearly", "pebbled",
        "placid", "playful", "pleasant", "plucky", "polar", "polished", "prairie", "prime",
        "pristine", "proud", "quaint", "quiet", "radiant", "rapid", "restful", "rippling",
        "rosy", "round", "royal", "ruddy", "rugged", "rural", "russet", "rustic",
        "sable", "saffron", "sage", "salty", "sandy", "sapphire", "scarlet", "scenic",
        "seaside", "serene", "shady", "shaggy", "sheer", "shimmering", "shining", "silent",
        "silken", "silver", "simple", "sleek", "slender", "smooth", "snowy", "soaring",
        "soft", "solar", "solemn", "sonic", "southern", "sparkling", "spirited", "spry",
        "stalwart", "starry", "steady", "stellar", "still", "stony", "stout", "sturdy",
        "sublime", "subtle", "summer", "sunlit", "sunny", "supple", "sweeping", "swift",
        "tawny", "teal", "tender", "thankful", "thriving", "tidal", "tidy", "timber",
        "tiny", "tranquil", "trusty", "twilight", "upland", "urban", "vast", "velvet",
        "verdant", "vibrant", "vivid", "warm", "western", "whispering", "wild", "windy",
        "winsome", "wintry", "wise", "woven", "zesty",
    ]

    /// Slot two. Landforms, weather, plants, minerals.
    public static let natureNouns: [String] = [
        "acorn", "agate", "alder", "almond", "amber", "arbor", "arroyo", "aspen",
        "aster", "atoll", "aurora", "azalea", "balsam", "bamboo", "basalt", "basin",
        "bayou", "beach", "bight", "birch", "blossom", "bluff", "boulder", "bramble",
        "branch", "breeze", "briar", "brook", "buckeye", "burrow", "butte", "cactus",
        "canopy", "canyon", "cascade", "cavern", "cedar", "chestnut", "cinder", "clay",
        "clearing", "cliff", "clover", "coast", "cobble", "comet", "copse", "coral",
        "cove", "crag", "creek", "crescent", "crest", "crocus", "current", "cypress",
        "daisy", "dale", "dawn", "delta", "dell", "desert", "dune", "dusk",
        "eddy", "elm", "ember", "estuary", "fern", "fjord", "flint", "flurry",
        "foam", "foothill", "forest", "fountain", "frost", "garnet", "geyser", "glacier",
        "glade", "glen", "granite", "grotto", "grove", "gulch", "gully", "harbor",
        "haven", "hazel", "heath", "hedge", "hemlock", "hillside", "hollow", "holly",
        "horizon", "inlet", "iris", "island", "ivy", "jasmine", "jasper", "juniper",
        "kelp", "knoll", "lagoon", "lake", "larch", "laurel", "ledge", "lichen",
        "lilac", "lily", "linden", "loam", "lotus", "lowland", "magnolia", "mangrove",
        "maple", "marble", "marsh", "meadow", "mesa", "mist", "moor", "moraine",
        "moss", "mountain", "mulberry", "myrtle", "nebula", "nettle", "oak", "oasis",
        "obsidian", "ocean", "onyx", "opal", "orchard", "orchid", "palm", "pasture",
        "peak", "pebble", "pine", "pinnacle", "plateau", "pollen", "pond", "poplar",
        "prairie", "quarry", "quartz", "rapids", "ravine", "redwood", "reef", "reed",
        "ridge", "rill", "river", "rose", "sagebrush", "sandbar", "sapling", "savanna",
        "sequoia", "shale", "shoal", "shore", "silt", "slate", "sleet", "slope",
        "snowfall", "sorrel", "spring", "spruce", "stone", "stream", "summit", "sunrise",
        "sunset", "surf", "swale", "sycamore", "thicket", "thistle", "tide", "topaz",
        "torrent", "trail", "tundra", "vale", "valley", "verbena", "vine", "violet",
        "vista", "wave", "willow", "wisteria", "woodland", "yarrow", "yew", "zephyr",
    ]

    /// Slot three. Animals and handmade objects.
    public static let creatureNouns: [String] = [
        "albatross", "anchor", "antler", "anvil", "atlas", "badger", "banner", "barrel",
        "basket", "beacon", "beaver", "bell", "bison", "blanket", "bobcat", "bookmark",
        "bottle", "bower", "bridge", "bugle", "bunting", "buoy", "cabin", "cairn",
        "camera", "candle", "canoe", "caravan", "cardinal", "carousel", "chalice", "chime",
        "chisel", "cipher", "clipper", "clock", "compass", "condor", "cottage", "coyote",
        "crane", "cricket", "crow", "cygnet", "dial", "dinghy", "dipper", "dolphin",
        "dormouse", "dove", "dragonfly", "drum", "eagle", "egret", "elk", "envelope",
        "ermine", "falcon", "fawn", "feather", "ferry", "finch", "firefly", "flagon",
        "flask", "flute", "forge", "fox", "frigate", "gable", "gander", "gazelle",
        "gecko", "gibbon", "glider", "gondola", "goose", "gosling", "grouse", "gull",
        "hammock", "hare", "harp", "hearth", "heron", "hive", "hound", "hummingbird",
        "ibex", "ibis", "inkwell", "jackdaw", "jaguar", "kayak", "kestrel", "kettle",
        "kingfisher", "kite", "koala", "lamp", "lantern", "lark", "lattice", "ledger",
        "lemur", "lighthouse", "lynx", "magpie", "mallard", "mandolin", "manor", "marmot",
        "marten", "meerkat", "minnow", "mirror", "mitten", "mockingbird", "mole", "mongoose",
        "moth", "narwhal", "nautilus", "nest", "newt", "nightingale", "notebook", "ocelot",
        "orca", "oriole", "osprey", "otter", "owl", "oyster", "packet", "paddle",
        "pagoda", "panda", "pangolin", "parasol", "parrot", "pavilion", "pelican", "pendant",
        "penguin", "petrel", "phoenix", "piano", "pigeon", "pipit", "plover", "plume",
        "porch", "portrait", "postcard", "prism", "puffin", "quail", "quill", "quilt",
        "rabbit", "raccoon", "raven", "ribbon", "robin", "rocket", "rudder", "saddle",
        "sailboat", "sandpiper", "satchel", "scarf", "schooner", "scroll", "seal", "shrike",
        "siskin", "skiff", "sloop", "snail", "sparrow", "spindle", "squirrel", "starling",
        "stork", "sundial", "swallow", "swan", "tanager", "tapestry", "teacup", "telescope",
        "tern", "thimble", "thrush", "ticket", "tiger", "toucan", "tower", "trawler",
        "trellis", "trolley", "trumpet", "tugboat", "turtle", "umbrella", "vase", "vessel",
        "violin", "vireo", "vole", "wagon", "walrus", "warbler", "weasel", "whale",
        "wheel", "whistle", "windmill", "wombat", "woodpecker", "wren", "yacht", "zebra",
    ]

    /// Number of distinct three-word slugs these pools can produce.
    ///
    /// This is the figure that decides whether a slug can be treated as a secret.
    /// See the enumeration note in the README before assuming it can.
    public static let keyspace = adjectives.count * natureNouns.count * creatureNouns.count
}
