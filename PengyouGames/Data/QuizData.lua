-- Data/QuizData.lua - the Quiz question bank, ported from Pengyou's Chat Games.
--
-- Data only. This file defines exactly one table on PG and does nothing else,
-- which is all file-scope purity permits; Games/Quiz.lua reads it at init, so
-- the .toc loads this file first.
--
-- Every client loads an IDENTICAL copy, and that is what lets the wire carry
-- question INDICES instead of question text: a Two Truths round travels as three
-- small numbers rather than three sentences that could never fit 200 bytes.
-- The corollary is that a player who opens this file can read the answers. That
-- was equally true of the addon this came from, and it is the right trade: these
-- are social games for raid downtime, the bank is not a secret, and the wire
-- budget is real.
--
-- Shape:
--   PG.QuizData.TypeRace   = { { word = "phrase to type" }, ... }
--   PG.QuizData.Unscramble = { { word = "answer", scrambled = "optional fixed jumble" }, ... }
--   PG.QuizData.Trivia     = { { q = "question", a = "answer", alt = { "other ok answers" } }, ... }
--   PG.QuizData.TwoTruths  = { truths = { "statement", ... }, lies = { "statement", ... } }
local ADDON, PG = ...

PG.QuizData = {}

--------------------------------------------------------------------------------
-- TYPE RACE MODULE (125 Phrases)
-- Format: { word = "the phrase to type" }
-- Players must type the exact phrase to win
--------------------------------------------------------------------------------
PG.QuizData.TypeRace = {
    -- Classic WoW Quotes & NPCs (1-30)
    { word = "Time is money friend" },
    { word = "Well met" },
    { word = "Zug zug" },
    { word = "Work work" },
    { word = "Something need doing" },
    { word = "Jobs done" },
    { word = "Me not that kind of orc" },
    { word = "Lok'tar ogar" },
    { word = "For the Horde" },
    { word = "For the Alliance" },
    { word = "Blood and thunder" },
    { word = "Victory or death" },
    { word = "Strength and honor" },
    { word = "May your blades never dull" },
    { word = "Light be with you" },
    { word = "Elune be with you" },
    { word = "Thrall bless you" },
    { word = "The light shall bring victory" },
    { word = "By the power of Ragnaros" },
    { word = "You are not prepared" },
    { word = "Suffer mortals as your pathetic magic betrays you" },
    { word = "Too soon you have awakened me too soon" },
    { word = "By fire be purged" },
    { word = "Die insect" },
    { word = "Flesh tearing bite of pain" },
    { word = "Now you feel pain" },
    { word = "Let the games begin" },
    { word = "Rise my soldiers rise and fight once more" },
    { word = "Citizens of Dalaran raise your eyes to the skies" },
    { word = "In the mountains" },
    
    -- Zone Names & Locations (31-40)
    { word = "The Barrens are a vast savanna" },
    { word = "Stormwind City stands proud" },
    { word = "Welcome to Orgrimmar" },
    { word = "The Dark Portal awaits" },
    { word = "Dalaran floats above Northrend" },
    { word = "Thunder Bluff rises high" },
    { word = "Ironforge burns with molten metal" },
    { word = "Silvermoon City shines eternal" },
    { word = "The Exodar crashed here" },
    { word = "Undercity lurks beneath" },
    
    -- Lore & Story (41-50)
    { word = "Arthas became the Lich King" },
    { word = "Illidan hunted demons" },
    { word = "Thrall freed the orcs" },
    { word = "Jaina founded Theramore" },
    { word = "Sylvanas leads the Forsaken" },
    { word = "Varian was High King" },
    { word = "Anduin seeks peace" },
    { word = "Garrosh went too far" },
    { word = "Deathwing shattered the world" },
    { word = "The titans shaped Azeroth" },
    
    -- Class & Gameplay (51-63)
    { word = "Hunters tame wild beasts" },
    { word = "Mages conjure arcane power" },
    { word = "Rogues strike from shadows" },
    { word = "Warriors charge into battle" },
    { word = "Paladins wield holy light" },
    { word = "Priests heal the wounded" },
    { word = "Shamans call upon elements" },
    { word = "Warlocks bind demons" },
    { word = "Druids shapeshift freely" },
    { word = "Death knights raise undead" },
    { word = "Monks seek inner peace" },
    { word = "Demon hunters sacrifice all" },
    { word = "Evokers channel draconic power" },
    
    -- Professions & Items (64-78)
    { word = "Blacksmiths forge weapons" },
    { word = "Alchemists brew potions" },
    { word = "Enchanters infuse magic" },
    { word = "Engineers build gadgets" },
    { word = "Tailors weave cloth armor" },
    { word = "Leatherworkers craft hides" },
    { word = "Jewelcrafters cut gems" },
    { word = "Scribes write glyphs" },
    { word = "Miners dig deep underground" },
    { word = "Herbalists gather plants" },
    { word = "Skinners collect leather" },
    { word = "Fishing requires patience" },
    { word = "Cooking feeds the raid" },
    { word = "First aid saves lives" },
    { word = "Archaeology uncovers relics" },
    
    -- Raid & Dungeon (79-88)
    { word = "Ready check in progress" },
    { word = "Pulling in three seconds" },
    { word = "Stack on the marker" },
    { word = "Spread out for mechanics" },
    { word = "Interrupt the cast now" },
    { word = "Healers save cooldowns" },
    { word = "Tanks swap at three stacks" },
    { word = "Bloodlust on the pull" },
    { word = "Wipe it up and reset" },
    { word = "Good job everyone" },
    
    -- Fun & Misc (89-100)
    { word = "Did someone say Thunderfury" },
    { word = "Leeroy at least had chicken" },
    { word = "More dots more dots" },
    { word = "Fifty DKP minus" },
    { word = "Handle it" },
    { word = "That is not even remotely imaginable" },
    { word = "Many whelps now handle it" },
    { word = "Whatever you do don't stand in fire" },
    { word = "Always check your repair bill" },
    { word = "Never pull when healer has no mana" },
    { word = "The Jailer was merely a setback" },
    { word = "Merely a setback" },

    -- Added in v2.2 (generated & verified)
    { word = "Frostmourne hungers" },
    { word = "There must always be a Lich King" },
    { word = "No king rules forever my son" },
    { word = "Light grant me one final blessing" },
    { word = "You no take candle" },
    { word = "The Horde is nothing" },
    { word = "You think you do but you don't" },
    { word = "Do you guys not have phones" },
    { word = "You face Jaraxxus Eredar Lord of the Burning Legion" },
    { word = "Prepare yourselves the bells have tolled" },
    { word = "Run away little girl run away" },
    { word = "The end has come let the unraveling of this world commence" },
    { word = "Storm earth and fire heed my call" },
    { word = "Imprisoned for ten thousand years" },
    { word = "Thunderfury Blessed Blade of the Windseeker" },
    { word = "Additional instances cannot be launched" },
    { word = "Don't forget your weekly vault" },
    { word = "The tank left after the first wipe" },
    { word = "Healer disconnected on the last boss" },
    { word = "Still no mount after ten years of farming" },
    { word = "Who pulled the extra pack" },
    { word = "Can someone summon the tank" },
    { word = "Mage table please" },
    { word = "Just one more quest then I log off" },
    { word = "I missed the zeppelin again" },
}

--------------------------------------------------------------------------------
-- UNSCRAMBLE MODULE (150 Words)
-- Format: { word = "answer", scrambled = "scrambled version" }
-- You can manually set scrambled, or leave it nil to auto-scramble.
-- Set scrambled manually when a random shuffle could spell a real word.
-- Use words of 4+ letters; very short words are trivial to unscramble.
--------------------------------------------------------------------------------
PG.QuizData.Unscramble = {
    -- Classes (1-13)
    { word = "Warrior" },
    { word = "Paladin" },
    { word = "Hunter" },
    { word = "Rogue", scrambled = "GUREO" },       -- fixed: random shuffle could show "ROUGE"
    { word = "Priest", scrambled = "RIPTES" },     -- fixed: could show "SPRITE"/"STRIPE"/"RIPEST"
    { word = "Shaman" },
    { word = "Mage", scrambled = "MGEA" },         -- fixed: could show "GAME"/"MEGA"
    { word = "Warlock" },
    { word = "Druid" },
    { word = "Monk" },
    { word = "Evoker", scrambled = "KOREVE" },  -- fixed: could show "REVOKE"
    { word = "Deathknight" },
    { word = "Demonhunter" },
    
    -- Races (14-35)
    { word = "Human" },
    { word = "Dwarf" },
    { word = "Gnome" },
    { word = "Nightelf" },
    { word = "Draenei" },
    { word = "Worgen" },
    { word = "Pandaren" },
    { word = "Troll" },
    { word = "Tauren", scrambled = "URNEAT" },     -- fixed: could show "NATURE"
    { word = "Undead" },
    { word = "Bloodelf" },
    { word = "Goblin", scrambled = "GONBIL" },  -- fixed: could show "GLOBIN"
    { word = "Vulpera" },
    { word = "Mechagnome" },
    { word = "Zandalari" },
    { word = "Nightborne" },
    { word = "Highmountain" },
    { word = "Maghar", scrambled = "GHAMRA" },  -- fixed: could show "GRAHAM"
    { word = "Kultiran" },
    { word = "Dracthyr" },
    { word = "Earthen", scrambled = "RETHANE" },   -- fixed: could show "HEARTEN"
    
    -- Cities (36-48)
    { word = "Stormwind", scrambled = "DNIWMROTS" },  -- fixed: could show "WINDSTORM"
    { word = "Orgrimmar" },
    { word = "Ironforge" },
    { word = "Darnassus" },
    { word = "Undercity" },
    { word = "Thunderbluff" },
    { word = "Silvermoon" },
    { word = "Exodar" },
    { word = "Dalaran" },
    { word = "Shattrath" },
    { word = "Boralus", scrambled = "LUROBAS" },  -- fixed: could show "LABOURS"
    { word = "Dazaralor" },
    { word = "Oribos" },
    
    -- Zones (49-95)
    { word = "Elwynn" },
    { word = "Westfall" },
    { word = "Duskwood" },
    { word = "Stranglethorn" },
    { word = "Tanaris", scrambled = "NARISTA" },  -- fixed: could show "ARTISAN"
    { word = "Winterspring" },
    { word = "Felwood" },
    { word = "Ashenvale" },
    { word = "Barrens" },
    { word = "Mulgore" },
    { word = "Durotar" },
    { word = "Tirisfal", scrambled = "SIRFATIL" },  -- fixed: could show "AIRLIFTS"
    { word = "Silverpine" },
    { word = "Hillsbrad" },
    { word = "Arathi" },
    { word = "Hinterlands" },
    { word = "Plaguelands" },
    { word = "Hellfire" },
    { word = "Zangarmarsh" },
    { word = "Nagrand" },
    { word = "Shadowmoon" },
    { word = "Netherstorm" },
    { word = "Dragonblight" },
    { word = "Zuldrak" },
    { word = "Sholazar" },
    { word = "Icecrown" },
    { word = "Deepholm" },
    { word = "Uldum" },
    { word = "Pandaria" },
    { word = "Krasarang" },
    { word = "Townlong" },
    { word = "Draenor", scrambled = "NODRAER" },  -- fixed: could show "ADORNER"
    { word = "Frostfire" },
    { word = "Gorgrond" },
    { word = "Talador" },
    { word = "Azsuna" },
    { word = "Valsharah" },
    { word = "Stormheim" },
    { word = "Suramar" },
    { word = "Argus", scrambled = "GARUS" },       -- fixed: could show "SUGAR"
    { word = "Zandalar" },
    { word = "Kultiras" },
    { word = "Nazjatar" },
    { word = "Mechagon" },
    { word = "Bastion", scrambled = "STOBIAN" },   -- fixed: could show "OBTAINS"
    { word = "Maldraxxus" },
    { word = "Ardenweald" },
    { word = "Revendreth" },
    { word = "Thaldraszus" },
    { word = "Valdrakken" },
    { word = "Zaralek" },
    
    -- Bosses & Characters (96-122)
    { word = "Ragnaros" },
    { word = "Onyxia" },
    { word = "Nefarian" },
    { word = "Chromaggus" },
    { word = "Hakkar" },
    { word = "Ossirian" },
    { word = "Kelthuzad" },
    { word = "Illidan" },
    { word = "Kaelthas" },
    { word = "Vashj" },
    { word = "Archimonde" },
    { word = "Kiljaeden" },
    { word = "Malygos" },
    { word = "Sartharion" },
    { word = "Yoggsaron" },
    { word = "Algalon" },
    { word = "Arthas" },
    { word = "Sindragosa" },
    { word = "Deathwing" },
    { word = "Neltharion" },
    { word = "Garrosh" },
    { word = "Guldan" },
    { word = "Azshara" },
    { word = "Sylvanas" },
    { word = "Denathrius" },
    { word = "Raszageth" },
    { word = "Fyrakk" },

    -- Added in v2.2 (generated & verified)
    { word = "Karazhan" },
    { word = "Ulduar" },
    { word = "Naxxramas" },
    { word = "Torghast" },
    { word = "Teldrassil" },
    { word = "Hallowfall" },
    { word = "Dornogal" },
    { word = "Silithus" },
    { word = "Gruul" },
    { word = "Magtheridon" },
    { word = "Moroes", scrambled = "RSOOEM" },   -- fixed: random shuffle could show "MOROSE"/"ROMEOS",
    { word = "Patchwerk" },
    { word = "Sapphiron" },
    { word = "Marrowgar" },
    { word = "Mannoroth" },
    { word = "Alakir" },
    { word = "Sargeras" },
    { word = "Medivh" },
    { word = "Khadgar" },
    { word = "Tyrande" },
    { word = "Malfurion" },
    { word = "Bwonsamdi" },
    { word = "Xalatath" },
    { word = "Frostmourne" },
    { word = "Ashbringer" },
}

--------------------------------------------------------------------------------
-- TRIVIA MODULE (141 Questions Spanning All Expansions)
-- Format: { q = "question", a = "correct answer", alt = {"alternate", "answers"} }
-- Matching is case-, punctuation-, and spacing-insensitive ("yoggsaron" matches
-- "Yogg-Saron"), and the full answer may be embedded in a longer sentence.
-- Fragments of the answer do NOT count. Use 'alt' for genuinely different
-- acceptable answers ("Arthas" for "The Lich King"), not punctuation variants.
-- IMPORTANT: never let the answer appear verbatim in the question text.
--------------------------------------------------------------------------------
PG.QuizData.Trivia = {
    --------------------------------------------------------------------------------
    -- VANILLA / CLASSIC (Questions 1-15)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in vanilla WoW?", a = "60" },
    { q = "What raid drops the bindings for Thunderfury?", a = "Molten Core" },
    { q = "Who is the final boss of Molten Core?", a = "Ragnaros" },
    { q = "What dragon drops the Tier 2 helm in vanilla?", a = "Onyxia" },
    { q = "What Old God is imprisoned beneath Ahn'Qiraj?", a = "C'Thun" },
    { q = "What volcanic peak between the Burning Steppes and Searing Gorge holds Molten Core and Blackwing Lair?", a = "Blackrock Mountain", alt = {"Blackrock"} },
    { q = "What 40-man raid is located in the Plaguelands?", a = "Naxxramas" },
    { q = "Who is the final boss of Blackwing Lair?", a = "Nefarian" },
    { q = "What zone contains the Scarlet Monastery?", a = "Tirisfal Glades" },
    { q = "What troll raid is located in Stranglethorn Vale?", a = "Zul'Gurub" },
    { q = "How many resources does a team need to win Arathi Basin in retail today?", a = "1500" },
    { q = "What class can use Feign Death?", a = "Hunter" },
    { q = "What color is Epic quality gear?", a = "Purple" },
    { q = "What color is Legendary quality gear?", a = "Orange" },
    { q = "What profession became the fourth secondary profession in Cataclysm?", a = "Archaeology" },
    
    --------------------------------------------------------------------------------
    -- THE BURNING CRUSADE (Questions 16-25)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in The Burning Crusade?", a = "70" },
    { q = "What shattered world did players explore in TBC?", a = "Outland" },
    { q = "Who is the final boss of the Black Temple?", a = "Illidan" },
    { q = "Name one of the two playable races added in The Burning Crusade.", a = "Blood Elf", alt = {"Blood Elves", "Draenei"} },
    { q = "What neutral city serves as a hub in Outland?", a = "Shattrath" },
    { q = "Who leads the blood elf forces in Tempest Keep?", a = "Kael'thas" },
    { q = "What is Lady Vashj's raid called?", a = "Serpentshrine Cavern" },
    { q = "What zone contains the Dark Portal on the Outland side?", a = "Hellfire Peninsula" },
    { q = "Who drops the legendary warglaives?", a = "Illidan" },
    { q = "What flying mounts come from the Netherwing faction?", a = "Netherdrakes", alt = {"Netherwing Drakes", "Netherwing Drake", "Nether Drakes", "Nether Drake", "Netherdrake", "Drakes"} },
    
    --------------------------------------------------------------------------------
    -- WRATH OF THE LICH KING (Questions 26-35)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Wrath of the Lich King?", a = "80" },
    { q = "What continent did WotLK add?", a = "Northrend" },
    { q = "Who was the Lich King's human identity?", a = "Arthas", alt = {"Bolvar", "Bolvar Fordragon"} },
    { q = "What hero class was introduced in WotLK?", a = "Death Knight" },
    { q = "What is the name of the Lich King's sword?", a = "Frostmourne" },
    { q = "Who was the first Lich King before Arthas merged with him?", a = "Ner'zhul" },
    { q = "What titan facility is located in the Storm Peaks?", a = "Ulduar" },
    { q = "What Old God is imprisoned beneath Ulduar?", a = "Yogg-Saron" },
    { q = "What is the name of the floating city above Northrend?", a = "Dalaran" },
    { q = "Who is the final boss of Icecrown Citadel?", a = "The Lich King", alt = {"Lich King", "Arthas"} },
    
    --------------------------------------------------------------------------------
    -- CATACLYSM (Questions 36-45)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Cataclysm?", a = "85" },
    { q = "What dragon destroyed and reshaped Azeroth in Cataclysm?", a = "Deathwing" },
    { q = "What was Deathwing's original name?", a = "Neltharion" },
    { q = "In what raid did players battle Ragnaros atop Sulfuron Keep during Cataclysm?", a = "Firelands", alt = {"The Firelands"} },
    { q = "Name one of the two playable races added in Cataclysm.", a = "Worgen", alt = {"Goblin", "Goblins"} },
    { q = "In what Cataclysm raid do players finally defeat Deathwing at the Maelstrom?", a = "Dragon Soul" },
    { q = "Who is the Firelord defeated in the Firelands?", a = "Ragnaros" },
    { q = "What aspect betrayed the other Dragon Aspects?", a = "Deathwing", alt = {"Neltharion"} },
    { q = "What underwater zone was added in Cataclysm?", a = "Vashj'ir" },
    { q = "Which dragonflight did Deathwing lead?", a = "Black", alt = {"Black Dragonflight", "The Black Dragonflight"} },
    
    --------------------------------------------------------------------------------
    -- MISTS OF PANDARIA (Questions 46-55)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Mists of Pandaria?", a = "90" },
    { q = "What new playable race was introduced in MoP?", a = "Pandaren" },
    { q = "What class was introduced in Mists of Pandaria?", a = "Monk" },
    { q = "What dark entities feed on negative emotions in Pandaria?", a = "Sha" },
    { q = "Who became corrupt and was the final boss of Siege of Orgrimmar?", a = "Garrosh" },
    { q = "What Old God's heart did Garrosh use to empower himself?", a = "Y'Shaarj" },
    { q = "What ancient race enslaved the pandaren?", a = "Mogu" },
    { q = "Who is the last Emperor of Pandaria?", a = "Shaohao" },
    { q = "What insectoid race is the ancient enemy of the pandaren?", a = "Mantid" },
    { q = "What Thunder King was resurrected by the Zandalari in MoP?", a = "Lei Shen" },
    
    --------------------------------------------------------------------------------
    -- WARLORDS OF DRAENOR (Questions 56-65)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Warlords of Draenor?", a = "100" },
    { q = "What alternate timeline world did WoD take place on?", a = "Draenor" },
    { q = "Who helped Garrosh escape to create the Iron Horde?", a = "Kairozdormu", alt = {"Kairoz"} },
    { q = "Who led the Iron Horde?", a = "Grommash Hellscream", alt = {"Grommash", "Grom"} },
    { q = "What warlord led the Blackrock clan and is a raid boss?", a = "Blackhand" },
    { q = "What player feature let you build your own base in WoD?", a = "Garrison" },
    { q = "What raid difficulty was added in WoD with a fixed 20-player size?", a = "Mythic" },
    { q = "Who is Thrall's mother that players meet in Maldraxxus and WoD?", a = "Draka" },
    { q = "What orc warlock became the main villain by the end of WoD?", a = "Gul'dan" },
    { q = "What is the final raid of Warlords of Draenor?", a = "Hellfire Citadel" },
    
    --------------------------------------------------------------------------------
    -- LEGION (Questions 66-75)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Legion?", a = "110" },
    { q = "What islands did players explore in Legion?", a = "Broken Isles" },
    { q = "What special weapons did each spec get in Legion?", a = "Artifact Weapons", alt = {"Artifacts", "Artifact", "Artifact Weapon"} },
    { q = "What new class was introduced in Legion?", a = "Demon Hunter" },
    { q = "Who is the fallen titan who founded the Burning Legion?", a = "Sargeras" },
    { q = "What Horde leader died at the Broken Shore?", a = "Vol'jin" },
    { q = "What Alliance leader died at the Broken Shore?", a = "Varian Wrynn", alt = {"Varian"} },
    { q = "Who became Warchief after Vol'jin died?", a = "Sylvanas" },
    { q = "What is the name of the dagger artifact for shadow priests?", a = "Xal'atath" },
    { q = "What titan world-soul was the final boss of Antorus, the Burning Throne?", a = "Argus", alt = {"Argus the Unmaker"} },
    
    --------------------------------------------------------------------------------
    -- BATTLE FOR AZEROTH (Questions 76-85)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Battle for Azeroth?", a = "120" },
    { q = "What resource leaked from Azeroth after Sargeras stabbed her?", a = "Azerite" },
    { q = "What tree city did Sylvanas burn at the start of BFA?", a = "Teldrassil", alt = {"Darnassus"} },
    { q = "What necklace did players use to power up in BFA?", a = "Heart of Azeroth" },
    { q = "What human kingdom did the Alliance recruit in BFA?", a = "Kul Tiras" },
    { q = "What troll empire did the Horde recruit in BFA?", a = "Zandalar" },
    { q = "Who is the Old God defeated in the final BFA raid?", a = "N'Zoth" },
    { q = "What Queen of the Naga was a raid boss in BFA?", a = "Azshara" },
    { q = "What orc rebel challenged Sylvanas and died at the gates of Orgrimmar?", a = "Saurfang", alt = {"Varok Saurfang"} },
    { q = "What is the final raid of Battle for Azeroth?", a = "Ny'alotha", alt = {"Nyalotha", "Ny'alotha the Waking City"} },
    
    --------------------------------------------------------------------------------
    -- SHADOWLANDS (Questions 86-92)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Shadowlands?", a = "60" },
    { q = "Which expansion sent players into the realm of the dead after Battle for Azeroth?", a = "Shadowlands" },
    { q = "What is the final boss of Castle Nathria?", a = "Sire Denathrius", alt = {"Denathrius"} },
    { q = "Name one of the four Covenants players could join in Shadowlands.", a = "Kyrian", alt = {"Necrolord", "Night Fae", "Venthyr", "Nightfae"} },
    { q = "Who is the main villain of Shadowlands known as the Jailer?", a = "Zovaal" },
    { q = "What zone is home to the angelic Kyrian?", a = "Bastion" },
    { q = "What zone is home to the vampiric Venthyr?", a = "Revendreth" },
    { q = "What tower in the Maw could players climb repeatedly?", a = "Torghast" },
    
    --------------------------------------------------------------------------------
    -- DRAGONFLIGHT (Questions 93-96)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in Dragonflight?", a = "70" },
    { q = "What islands awakened after 10000 years in Dragonflight?", a = "Dragon Isles" },
    { q = "What new playable race was added in Dragonflight?", a = "Dracthyr" },
    { q = "What Primal Incarnate was the final boss of Vault of the Incarnates?", a = "Raszageth" },
    
    --------------------------------------------------------------------------------
    -- THE WAR WITHIN (Questions 97-100)
    --------------------------------------------------------------------------------
    { q = "What was the level cap in The War Within?", a = "80" },
    { q = "Who is the main villain called the Harbinger of the Void?", a = "Xal'atath" },
    { q = "What underground insectoid race serves Xal'atath?", a = "Nerubians", alt = {"Nerubian"} },
    { q = "What nerubian queen betrayed her mother to ally with Xal'atath?", a = "Ansurek", alt = {"Queen Ansurek"} },

    -- The War Within, Midnight & more (added in v2.2, generated & verified)
    { q = "What new continent, stretching from the Isle of Dorn down to the depths of Azj-Kahet, was explored in The War Within?", a = "Khaz Algar" },
    { q = "What Earthen city is the capital of Khaz Algar?", a = "Dornogal" },
    { q = "What explorable mini-dungeons introduced in The War Within pair you with Brann Bronzebeard as a companion?", a = "Delves", alt = {"Delve"} },
    { q = "What account-wide system introduced in The War Within lets your characters share a bank, gold, and reputations?", a = "Warbands", alt = {"Warband"} },
    { q = "What extra class trees with names like Mountain Thane and Voidweaver debuted in The War Within?", a = "Hero Talents", alt = {"Hero Talent"} },
    { q = "What was the first raid of The War Within?", a = "Nerub-ar Palace" },
    { q = "What goblin capital city inside the Isle of Kezan became explorable in patch 11.1?", a = "Undermine" },
    { q = "What former trade prince is the final boss of the Liberation of Undermine raid?", a = "Chrome King Gallywix", alt = {"Gallywix"} },
    { q = "What shattered world is the original homeland of the ethereals?", a = "K'aresh" },
    { q = "What void lord is the final boss of the Manaforge Omega raid?", a = "Dimensius" },
    { q = "What is the level cap in the Midnight expansion?", a = "90" },
    { q = "What elven kingdom, invaded by the Void, is the setting of Midnight?", a = "Quel'Thalas" },
    { q = "What new allied race, whose homeland is Harandar, became playable in Midnight?", a = "Haranir" },
    { q = "What long-requested feature of the Midnight era finally lets every player own and decorate a home?", a = "Player Housing", alt = {"Housing"} },
    { q = "What ranged third specialization did demon hunters gain in Midnight?", a = "Devourer" },
    { q = "What was the first raid of the Midnight expansion?", a = "The Voidspire", alt = {"Voidspire"} },
    { q = "What sprawling Dark Iron dungeon is home to Emperor Dagran Thaurissan and the Grim Guzzler tavern?", a = "Blackrock Depths", alt = {"BRD"} },
    { q = "What dungeon in the Barrens is the den of the Druids of the Fang?", a = "Wailing Caverns" },
    { q = "In what Icecrown dungeon do players flee from the Lich King alongside Jaina or Sylvanas?", a = "Halls of Reflection" },
    { q = "What capture-the-flag battleground lies on the border of Ashenvale and the Barrens?", a = "Warsong Gulch", alt = {"WSG"} },
    { q = "What Frostwolf general leads the Horde in Alterac Valley?", a = "Drek'Thar" },
    { q = "In what Pandaria battleground do teams earn points by holding the Orbs of Power?", a = "Temple of Kotmogu", alt = {"Kotmogu"} },
    { q = "What Draenor island hosts the epic battleground where Stormshield clashes with Warspear?", a = "Ashran" },
    { q = "What profession crafts the Vial of the Sands, which turns its drinker into a rideable Sandstone Drake?", a = "Alchemy", alt = {"Alchemist"} },
    { q = "What engineering mount lets herbalists gather herbs without dismounting?", a = "Sky Golem" },
    { q = "What Dragonflight system lets you pay other players to make items for you through a public board?", a = "Crafting Orders", alt = {"Crafting Order"} },
    { q = "What secondary profession was removed from the game in Battle for Azeroth?", a = "First Aid" },
    { q = "What phoenix mount can drop when Kael'thas falls in Tempest Keep?", a = "Ashes of Al'ar", alt = {"Al'ar"} },
    { q = "What ghostly winged horse drops from the Lich King in Icecrown Citadel?", a = "Invincible" },
    { q = "What rare spawn circling the Storm Peaks is famously camped for its mount?", a = "Time-Lost Proto-Drake", alt = {"TLPD"} },
    { q = "What mounted Karazhan boss drops the Fiery Warhorse's Reins?", a = "Attumen" },
    { q = "What haunted tower in Deadwind Pass served as the first raid of The Burning Crusade?", a = "Karazhan" },
    { q = "In what raid did players stop Kil'jaeden from being fully summoned into Azeroth?", a = "Sunwell Plateau", alt = {"Sunwell"} },
    { q = "What Ulduar boss could originally be fought for only one hour each week?", a = "Algalon" },
    { q = "What Wrath raid takes place entirely inside a coliseum at the Argent Tournament?", a = "Trial of the Crusader", alt = {"Trial of the Grand Crusader"} },
    { q = "In what Mists of Pandaria raid was Lei Shen defeated for good?", a = "Throne of Thunder" },
    { q = "In what Zereth Mortis raid was the Jailer finally defeated?", a = "Sepulcher", alt = {"Sepulcher of the First Ones"} },
    { q = "What Primal Incarnate fell at Amirdrassil in Dragonflight's final raid?", a = "Fyrakk" },
    { q = "What raid in Zaralek Cavern held Neltharion's secret laboratory?", a = "Aberrus", alt = {"Aberrus the Shadowed Crucible"} },
    { q = "What class introduced alongside the dracthyr spends Essence on its abilities?", a = "Evoker" },
}

--------------------------------------------------------------------------------
-- TWO TRUTHS AND A LIE MODULE (125 truths, 120 lies)
-- Base pools imported from wow_facts_and_lies.xlsx, fact-checked and corrected
-- against warcraft.wiki.gg; expanded in v2.2 with generated & verified entries.
-- The truths and lies columns are unrelated to each other (not paired).
-- Each round shows two random truths and one lie; players answer A/B/C.
-- Keep every statement under ~170 characters (chat lines cap at 255 bytes
-- and the answer-reveal line adds ~80 bytes of wrapper text), factually
-- airtight (truths) or clearly false to a knowledgeable player (lies), and
-- written in the same neutral style so the lie doesn't stand out by tone.
--------------------------------------------------------------------------------
PG.QuizData.TwoTruths = {
    truths = {
        "Arthas Menethil was the crown prince of Lordaeron before he claimed Frostmourne.",
        "Tirion Fordring shattered Frostmourne with the Ashbringer at the Frozen Throne.",
        "The Lich King's crown is called the Helm of Domination.",
        "Ner'zhul, an orc shaman of the Shadowmoon clan, was the first Lich King.",
        "Bolvar Fordragon took up the Helm of Domination after Arthas fell.",
        "Thrall's birth name is Go'el; he is the son of Durotan and Draka.",
        "Durotar is named after Thrall's father, Durotan.",
        "Orgrimmar is named after Orgrim Doomhammer.",
        "Grommash Hellscream killed the pit lord Mannoroth, freeing the orcs from the blood curse.",
        "Garrosh Hellscream is the son of Grommash Hellscream.",
        "Garrosh destroyed Theramore with a mana bomb.",
        "Cairne Bloodhoof died fighting Garrosh in a mak'gora duel.",
        "Baine Bloodhoof succeeded his father as chieftain of the tauren.",
        "Thunder Bluff sits atop the mesas of Mulgore.",
        "Vol'jin led the Darkspear tribe and later served as Warchief of the Horde.",
        "The Darkspear trolls made their home on the Echo Isles, off the coast of Durotar.",
        "Sylvanas Windrunner was Ranger-General of Silvermoon before Arthas raised her as a banshee.",
        "The Forsaken made their capital in the Undercity, beneath the ruins of Lordaeron.",
        "Alleria and Vereesa Windrunner are Sylvanas's sisters.",
        "Silvermoon City is the capital of the blood elves.",
        "The blood elves took their name in memory of those slain during the Scourge invasion of Quel'Thalas.",
        "Kael'thas Sunstrider was the last prince of the Sunstrider line.",
        "The Sunwell was restored using the spark of the naaru M'uru.",
        "The draenei fled Argus rather than accept Sargeras's offer.",
        "Velen is the prophet who leads the draenei.",
        "Kil'jaeden and Archimonde once led the eredar alongside Velen on Argus.",
        "Sargeras founded the Burning Legion.",
        "Medivh was the Guardian of Tirisfal and was possessed by Sargeras.",
        "Medivh opened the Dark Portal, letting the orcish Horde into Azeroth.",
        "Karazhan is Medivh's abandoned tower in Deadwind Pass.",
        "Outland is what remains of the shattered world of Draenor.",
        "Illidan Stormrage ruled the Black Temple, formerly the draenei temple of Karabor.",
        "Illidan and Malfurion Stormrage are twin brothers.",
        "Tyrande Whisperwind is the High Priestess of Elune.",
        "Elune is the moon goddess worshipped by the night elves.",
        "Cenarius is the son of Elune and the demigod Malorne.",
        "Cenarius was slain by Grommash Hellscream in Ashenvale.",
        "Queen Azshara ruled the night elf empire and became the queen of the naga.",
        "The destruction of the Well of Eternity caused the Sundering, splitting Kalimdor apart.",
        "Nordrassil is the world tree atop Mount Hyjal.",
        "Archimonde was destroyed at Mount Hyjal by wisps drawn from Nordrassil.",
        "Teldrassil was burned on Sylvanas's order at the start of the fourth war.",
        "Lady Vashj served Illidan and was defeated in Serpentshrine Cavern.",
        "Deathwing was once Neltharion, the Earth-Warder and Aspect of the black dragonflight.",
        "Alexstrasza the Life-Binder leads the red dragonflight.",
        "Nozdormu is the Aspect of Time and leads the bronze dragonflight.",
        "Ysera, the Dreamer, was the green Aspect and guardian of the Emerald Dream.",
        "Malygos was the Aspect of Magic and leader of the blue dragonflight.",
        "Nozdormu's corrupted future self is Murozond.",
        "Onyxia infiltrated Stormwind disguised as the human noble Lady Katrana Prestor.",
        "Nefarian posed as Lord Victor Nefarius in Blackrock Spire.",
        "Onyxia and Nefarian are both children of Deathwing.",
        "Ragnaros the Firelord was summoned by the Dark Iron dwarves beneath Blackrock Mountain.",
        "Ragnaros returned as the final boss of the Firelands after his defeat in Molten Core.",
        "Deathwing's return shattered Azeroth in the Cataclysm.",
        "Deepholm is the Elemental Plane of Earth, ruled by Therazane the Stonemother.",
        "C'Thun is the Old God imprisoned within the Temple of Ahn'Qiraj.",
        "Yogg-Saron is the Old God bound beneath Ulduar.",
        "N'Zoth was the Old God behind the Emerald Nightmare and the creation of the naga.",
        "Y'Shaarj was the Old God torn from Pandaria by the titans.",
        "The sha are manifestations of negative emotion born from Y'Shaarj's dying breath.",
        "Pandaria was hidden behind a shroud of mist for roughly ten thousand years.",
        "The mogu once enslaved the pandaren, who rebelled under Kang, the Fist of First Dawn.",
        "Chen Stormstout is a wandering pandaren brewmaster.",
        "Azeroth itself is a nascent titan world-soul.",
        "Azerite surfaced after Sargeras drove his sword into Silithus.",
        "Uldaman, Ulduar, and Uldum are all titan facilities.",
        "The Curse of Flesh transformed titan-forged beings into the mortal dwarves, gnomes, and humans.",
        "The vrykul are the ancestors of humanity.",
        "Loken was a titan keeper corrupted by Yogg-Saron.",
        "Algalon the Observer was sent to judge whether Azeroth should be re-originated.",
        "Ironforge is the dwarven capital, carved into the mountains of Dun Morogh.",
        "Gnomeregan was irradiated and lost, driving the gnomes to shelter in Ironforge.",
        "The Deeprun Tram connects Stormwind and Ironforge.",
        "The Stonemasons Guild rebuilt Stormwind, and their betrayal birthed the Defias Brotherhood.",
        "Edwin VanCleef led the Defias Brotherhood from the Deadmines.",
        "Hogger is a notorious gnoll of Elwynn Forest.",
        "Varian Wrynn died covering the Alliance retreat from the Broken Shore.",
        "Anduin Wrynn is Varian's son and became King of Stormwind.",
        "Jaina Proudmoore is the daughter of Admiral Daelin Proudmoore of Kul Tiras.",
        "Boralus is the capital of Kul Tiras.",
        "Dazar'alor is the capital of the Zandalari trolls.",
        "Dalaran was governed by the Kirin Tor and floated above the ground until its destruction at the start of the War Within.",
        "Khadgar was Medivh's apprentice and later led the Kirin Tor.",
        "Genn Greymane ruled Gilneas and ordered the building of the Greymane Wall.",
        "The worgen of Gilneas joined the Alliance after the Cataclysm.",
        "The goblins of the Bilgewater Cartel joined the Horde after fleeing Kezan.",
        "The nightborne of Suramar were sustained by the Nightwell for ten thousand years.",
        "Death knights begin in Acherus: The Ebon Hold, a floating necropolis.",
        "Demon hunters are playable only by night elves, blood elves, and void elves.",
        "Evokers are dracthyr, created by Neltharion and trained in the Forbidden Reach.",
        "Tirion Fordring founded the Argent Crusade.",
        "The Ashbringer was first wielded by Highlord Alexandros Mograine.",
        "Darion Mograine is Alexandros's son and leads the Knights of the Ebon Blade.",
        "Renault Mograine corrupted the Ashbringer by murdering his own father with it.",
        "The Scarlet Monastery lies within Tirisfal Glades.",
        "Kel'Thuzad founded the Cult of the Damned and ruled Naxxramas as a lich.",
        "Shattrath City is divided between the Aldor and the Scryers.",
        "The Caverns of Time in Tanaris are guarded by the bronze dragonflight.",
        "A hearthstone returns its owner to the inn where it is bound.",

    -- Added in v2.2 (generated & verified)
        "King Rastakhan was slain during the Alliance assault on Dazar'alor.",
        "Talanji succeeded her father Rastakhan as ruler of the Zandalari.",
        "Jaina Proudmoore became Lord Admiral of Kul Tiras during Battle for Azeroth.",
        "The vulpera of Vol'dun joined the Horde as a playable allied race in Battle for Azeroth.",
        "Queen Azshara parted the ocean to drag the Horde and Alliance fleets down into Nazjatar.",
        "Xal'atath was freed from her dagger prison during Battle for Azeroth.",
        "Sylvanas abandoned the Horde after her mak'gora with Varok Saurfang at the gates of Orgrimmar.",
        "Sylvanas shattered the Helm of Domination atop Icecrown Citadel, tearing open the veil to the Shadowlands.",
        "Kel'Thuzad returned in Shadowlands as a baron of the House of Rituals in Maldraxxus.",
        "The Runecarver imprisoned in Torghast was revealed to be the Primus of Maldraxxus.",
        "After his defeat in Castle Nathria, Sire Denathrius was sealed inside his own sword, Remornia.",
        "In the Shadowlands, the soul of Uther the Lightbringer helped cast Arthas's soul into the Maw.",
        "The kyrian Pelagos became the new Arbiter of the Shadowlands.",
        "The Jailer used a dominated Anduin Wrynn to open the Sepulcher of the First Ones.",
        "Though Raszageth fell in the Vault of the Incarnates, her assault on its prison freed Fyrakk, Vyranoth, and Iridikron.",
        "Vyranoth abandoned Fyrakk and fought beside the dragonflights to defend Amirdrassil.",
        "Fyrakk fell at Amirdrassil after seeking to consume the new world tree's power.",
        "Wrathion and Sabellian both stepped aside, leaving Ebyssian to lead the black dragonflight.",
        "After Amirdrassil bloomed, the night elves founded a new capital, Bel'ameth, beneath its boughs.",
        "Dornogal, capital of the earthen, stands on the Isle of Dorn in Khaz Algar.",
        "The earthen of Khaz Algar became a playable allied race in The War Within.",
        "Beledar, the immense crystal above Hallowfall, periodically shifts from Light to Void energy.",
        "Faerin Lothar, an Arathi Lamplighter, fights alongside players in Hallowfall.",
        "Chrome King Gallywix is the final boss of the Liberation of Undermine raid.",
        "Dimensius the All-Devouring is the final boss of the Manaforge Omega raid on K'aresh.",
    },
    lies = {
        "Arthas was knighted into the Order of the Silver Hand by Uther on his sixteenth birthday.",
        "Frostmourne was forged by Yogg-Saron and gifted to Ner'zhul in exchange for his service.",
        "The Lich King's throne room is known as the Halls of Reflection.",
        "Ner'zhul was chieftain of the Frostwolf clan before his ascension.",
        "Bolvar Fordragon was Arthas's boyhood sparring partner in Lordaeron's royal court.",
        "Thrall's younger sister, Draka the Lesser, died in the internment camps.",
        "Durotar was named by Cairne Bloodhoof as a gift to the young Warchief.",
        "Orgrimmar was called Grommashar for its first year, before Thrall renamed it.",
        "Grommash Hellscream drank Mannoroth's blood a second time to gain the strength to kill him.",
        "Garrosh Hellscream was named Warchief by Vol'jin, who later regretted it.",
        "Theramore was destroyed when goblin saboteurs detonated a fel reactor beneath the keep.",
        "Cairne Bloodhoof fell to a poison Garrosh knowingly smeared on Gorehowl.",
        "Baine Bloodhoof retook Thunder Bluff with the aid of the Grimtotem tribe.",
        "Thunder Bluff's mesas are joined by stone bridges carved by earthen artisans.",
        "Vol'jin was assassinated by agents of Sylvanas during the Broken Shore campaign.",
        "The Darkspear were driven from the Echo Isles by the Amani warlord Zul'jin.",
        "Sylvanas served as Ranger-General of Silvermoon for over three hundred years.",
        "The Undercity was rendered uninhabitable when Alliance forces detonated Forsaken Blight during the Battle for Lordaeron.",
        "Alleria Windrunner was the first mortal ever to wield the Holy Light in battle.",
        "The scar the Scourge carved through Silvermoon is called the Bleeding Scar.",
        "The blood elves renamed themselves at Kael'thas's command after his death at Tempest Keep.",
        "Kael'thas Sunstrider, son of Anasterian, met his end in the Sunwell Plateau.",
        "The Sunwell was restored with water carried back from the Well of Eternity through the Caverns of Time.",
        "The Exodar crashed on Bloodmyst Isle, staining the ground red with fel crystal.",
        "Farseer Nobundo, the first draenei shaman, is Velen's older brother.",
        "Kil'jaeden and Archimonde were Velen's blood brothers before the eredar split.",
        "Sargeras served the Pantheon under the title of the Highfather.",
        "Aegwynn sealed Sargeras's spirit in the cellars beneath Karazhan.",
        "Medivh opened the Dark Portal alongside the ogre-mage Cho'gall.",
        "Karazhan's opera house is haunted by Moroes, Medivh's first apprentice.",
        "Outland was shattered when Illidan turned the Eye of Sargeras on the world.",
        "The Black Temple was raised by the ogres of Highmaul long before the draenei arrived.",
        "Illidan Stormrage was imprisoned beneath Hyjal for one hundred years.",
        "Tyrande chose Malfurion over Illidan at the Temple of the Moon in Zin-Azshari.",
        "Elune granted the night elves their immortality as a reward for the War of the Ancients.",
        "Cenarius fathered the wild demigods Ursoc and Ursol.",
        "Azshara's handmaidens were reshaped into the first naga by Sargeras himself.",
        "The Sundering created the Maelstrom above the drowned ruins of Suramar.",
        "Nordrassil grew from a seed planted atop Hyjal by Fandral Staghelm.",
        "Archimonde was destroyed when Malfurion detonated Nordrassil's roots beneath him.",
        "Teldrassil was burned by Nathanos Blightcaller acting without Sylvanas's knowledge.",
        "Lady Vashj, once Azshara's handmaiden, was slain in Coilfang's Steamvault.",
        "Deathwing's original title among the Aspects was the Stone-Warder.",
        "Alexstrasza was granted her dominion over life by the titan Norgannon.",
        "Nozdormu is fated to become the chromatic horror Chromatus.",
        "Ysera was killed in the Emerald Nightmare by the satyr lord Xavius.",
        "Malygos was struck down by Alexstrasza herself at the close of the Nexus War.",
        "Onyxia, posing as Lady Prestor, served as regent to the boy-king Anduin.",
        "Nefarian's chromatic experiments produced Chromaggus deep in Blackrock Depths.",
        "Deathwing's elementium plates were riveted on by the Dark Iron dwarves of Shadowforge.",
        "Ragnaros was bound to the Molten Core by the titan keeper Ra-den.",
        "Majordomo Executus was once a Dark Iron dwarf lord before Ragnaros remade him.",
        "Deepholm answers to Neptulon the Tidehunter.",
        "Al'Akir the Windlord was slain within the Bastion of Twilight.",
        "C'Thun was imprisoned in Ahn'Qiraj by the titan watcher Odyn.",
        "Yogg-Saron's prison was designed and built by the keeper Mimiron.",
        "N'Zoth lay imprisoned beneath the Vale of Eternal Blossoms.",
        "Y'Shaarj's heart was buried beneath the Temple of the Red Crane.",
        "The Sha of Pride was bound beneath the Temple of the White Tiger.",
        "Pandaria was concealed by mists raised by the jade serpent Yu'lon.",
        "Lei Shen was resurrected inside the Mogu'shan Vaults.",
        "Li Li Stormstout is the granddaughter of Kang, the first brewmaster.",
        "Azeroth's world-soul was wounded when Sargeras drove his blade into Northrend.",
        "Azerite was first unearthed by Kul Tiran miners working the hills of Drustvar.",
        "Ulduar was raised by Odyn to serve as the vault of the Halls of Valor.",
        "The Curse of Flesh was cast on the titan-forged by Loken at Sargeras's command.",
        "The vrykul cast out their undersized offspring, who became the first gnomes.",
        "Loken was the youngest of the keepers and served as gatekeeper of Ulduar.",
        "Algalon's defeat convinced the Pantheon to spare Azeroth permanently.",
        "Ironforge's Great Forge was lit by Khaz'goroth's own hand and has never gone out.",
        "Gnomeregan was irradiated on the orders of Mekkatorque's rival, Gelbin Thermaplugg.",
        "The Deeprun Tram once had a third station in Loch Modan, sealed after a cave-in.",
        "The Stonemasons Guild was led by Rufus VanCleef, Edwin's father.",
        "The Deadmines lie beneath Sentinel Hill in Westfall.",
        "Hogger served as a lieutenant to the Riverpaw chieftain, Shadowclaw.",
        "Varian Wrynn was killed by Kil'jaeden's own hand at the Broken Shore.",
        "Anduin was crowned at eighteen, after a two-year regency under Genn Greymane.",
        "Derek Proudmoore was raised into undeath by his own mother, Katherine.",
        "Boralus is governed by the Ashvane Trading Company.",
        "Dazar'alor was founded by Zul the Prophet, ancestor of King Rastakhan.",
        "Rhonin lifted Dalaran into the sky using the Focusing Iris.",
        "Khadgar's white hair was the price he paid for sealing the Dark Portal after the Second War.",
        "Liam Greymane was killed by Nathanos Blightcaller during the siege of Gilneas City.",
        "The worgen curse began with the Druids of the Pack, a circle led by Fandral Staghelm.",
        "Trade Prince Gallywix was overthrown by Thrall during the evacuation of Kezan.",
        "The Nightwell was powered by the Tidestone of Golganneth.",
        "The Knights of the Ebon Blade were founded by Tirion Fordring after Light's Hope Chapel.",
        "Illidan trained his first demon hunters inside the Vault of the Wardens.",
        "The dracthyr slept in stasis beneath Valdrakken until the Dragon Isles reopened.",
        "Monks were the first class in the game incapable of equipping a weapon.",
        "The Argent Tournament grounds were raised by the Argent Dawn before the war on the Scourge.",
        "The Ashbringer was forged around a crystal recovered from the Scarlet Monastery.",
        "Darion Mograine commands the Ebon Blade from a war room inside Naxxramas.",
        "The Scarlet Monastery stands in the Western Plaguelands.",
        "Icecrown Citadel was raised by the Lich King's val'kyr in a single night.",
        "Naxxramas was anchored directly above Wyrmrest Temple after its move to Northrend.",
        "The Aldor of Shattrath are led by Voren'thal the Seer, the Scryers by High Priestess Ishanah.",
        "Nozdormu sealed the Caverns of Time after the infinite dragonflight's first incursion.",
        "The hearthstone's cooldown was set at two full hours by the Innkeepers' Guild.",
        "Every capital has an innkeeper except Orgrimmar, where the Valley of Strength tavern serves instead.",

    -- Added in v2.2 (generated & verified)
        "Kyrestia the Firstborne served as the Arbiter, judging souls in Oribos.",
        "In Ardenweald, anima tithes are gathered by the Court of Harvesters.",
        "Ve'nari, a night fae exile, aids adventurers stranded in the Maw.",
        "The undead armies of Maldraxxus are divided among seven great houses.",
        "The Jailer forged Kingsmourne from the recovered shards of Frostmourne.",
        "Zereth Mortis was built by the titan Pantheon as their first great workshop.",
        "Tyrande slew Nathanos Blightcaller in the groves of Ardenweald.",
        "Tyrande passed the mantle of the Night Warrior to Shandris Feathermoon.",
        "The Jailer met his final defeat in the Sanctum of Domination.",
        "The titan quarantine facility Uldir lies buried beneath the sands of Vol'dun.",
        "G'huun was the fifth Old God, sealed beneath Nazmir by the titan keepers.",
        "Mechagon Island lies off the northern coast of Zandalar.",
        "Anduin Wrynn wielded the Ashbringer during the Battle for Lordaeron.",
        "Khadgar forged the Heart of Azeroth and entrusted it to Azeroth's champions.",
        "The Vault of the Incarnates lies hidden beneath the Azure Span.",
        "Kalecgos stepped down during Dragonflight, naming Senegos leader of the blue dragonflight.",
        "Iridikron the Stonescale was slain by Alexstrasza at the gates of Aberrus.",
        "The Machine Speakers of the Ringing Deeps are a society of mechagnomes.",
        "Undermine, the goblin capital, was carved out beneath the Isle of Dorn.",
        "Faerin Lothar is the granddaughter of the Alliance hero Anduin Lothar.",
    },
}

--------------------------------------------------------------------------------
-- ADDING NEW QUESTIONS
--
-- To add more questions to any module, simply add new entries to the tables above.
-- Follow the format shown for each module type.
--
-- TYPE RACE - Adding a new phrase:
--     { word = "Your new phrase here" },
--
-- UNSCRAMBLE - Adding a new word:
--     { word = "YourWord" },
--     -- Or with a custom scrambled version:
--     { word = "YourWord", scrambled = "ruoYdWor" },
--
-- TRIVIA - Adding a new question:
--     { q = "Your question here?", a = "The Answer" },
--     -- Or with alternative accepted answers:
--     { q = "Your question here?", a = "The Answer", alt = {"Alt1", "Alt2"} },
--
--------------------------------------------------------------------------------