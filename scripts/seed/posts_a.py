# Batch one. Each entry: author handle, category, mood, hours old, the post,
# and the replies it drew, in order.
POSTS_A = [
 dict(a="keza_k", c="campus_life", m="exhausted", h=2, t=(
   "Finished my last paper at 4am and walked home when the buses started. "
   "Nobody clapped. I just sat on my bed with my shoes still on for twenty "
   "minutes. Is this what finishing feels like?"),
   k=[("nightshift","The shoes-still-on part. I know exactly that twenty minutes."),
      ("softlanding","It hits three days later usually. Give it until Thursday."),
      ("almostthere","Congratulations. Genuinely. You did a hard thing while tired."),
      ("stilllearning","Sit in it. You earned the sitting.")]),

 dict(a="wanjiru_w", c="family_issues", m="angry", h=5, t=(
   "My brother asked me for money again and when I said I don't have it he "
   "said 'but you're the one working'. I am also the one who paid for his "
   "school. I am also the one nobody asks how I'm doing."),
   k=[("zainab_h","Eldest daughter tax. Nobody itemises it but we all pay it."),
      ("nia_m","You are allowed to say no and still love him. Both."),
      ("esi_a","'You're the one working' is not a job description."),
      ("yaa_serwaa","I said no for the first time in December. The sky stayed up.")]),

 dict(a="tunde_a", c="trauma", m="broken", h=9, t=(
   "Six months today. I keep reaching for my phone to tell him things. "
   "Yesterday I found a voice note he sent me about football and I have "
   "listened to it maybe forty times."),
   k=[("rehema_j","Two years for me. I still have three saved. You don't have to ration them."),
      ("saltwater","The reaching for the phone never fully stops. It just gets quieter."),
      ("gloria_u","Forty times is not too many. There's no number that's too many.")]),

 dict(a="bosco_r", c="mental_health", m="hopeful", h=1, t=(
   "Third therapy session today. First one where I didn't spend the whole "
   "hour making her laugh."),
   k=[("patrick_n","That's the actual work. Congratulations, seriously."),
      ("ama_writes","Making them laugh is the armour. Putting it down is huge."),
      ("neema_s","Your therapist noticed too, I promise you.")]),

 dict(a="just_t", c="confessions", m="lonely", h=14, t=(
   "I have 900 followers somewhere else and nobody to call at 9pm on a "
   "Tuesday. I don't know how that happened."),
   k=[("halfmoon","Same, and I think it happened slowly enough that I didn't see it."),
      ("farfromhome","9pm Tuesday is the loneliest hour that exists."),
      ("quietstorm","Following is not the same as knowing. Nobody warns you."),
      ("velvethour","Would you have picked up if someone called you though? I wouldn't have.")]),

 dict(a="chidi_nma", c="faith_spirituality", m="confused", h=20, t=(
   "I still pray but I don't know who I'm talking to anymore. I haven't "
   "told anyone at church that. They'd pray for me and that would make it "
   "worse somehow."),
   k=[("kwame_b","Praying while unsure is still praying. I'd argue it's the harder kind."),
      ("claude_ii","I went through two years of that. Came out somewhere different but not empty."),
      ("abena_o","The fear of being prayed AT. I felt that in my chest.")]),

 dict(a="lowbattery", c="adulting", m="exhausted", h=3, t=(
   "Payday was Friday. It is Tuesday. Where."),
   k=[("greenlight","Rent, and then a small betrayal at the supermarket."),
      ("femi_o","The supermarket betrayal is real. I went in for bread."),
      ("mangoseason","I now transfer half to a different account the same hour it lands. It's the only thing that worked.")]),

 dict(a="uwase_c", c="mental_health", m="anxious", h=7, t=(
   "Everyone keeps saying 'just put yourself out there' like the problem is "
   "that I haven't thought of it."),
   k=[("halfmoon","As if we're sitting at home going ah, what a novel idea."),
      ("stilllearning","The advice assumes the hard part is the decision. It's never the decision."),
      ("softlanding","I started with one text to one person once a week. Small enough to actually do.")]),

 dict(a="ines_g", c="relationships", m="sad", h=26, t=(
   "He's not a bad man. He's just not curious about me. Three years and he "
   "has never once asked a follow-up question."),
   k=[("nia_m","'Not curious about me' is the most precise description of a dying thing I've read here."),
      ("diane_mu","The follow-up question is the whole relationship honestly."),
      ("wanjiru_w","Not bad is not the bar. I had to learn that the long way.")]),

 dict(a="smallhours", c="late_night", m="overthinking", h=11, t=(
   "2:14am. Replaying a conversation from 2019 where I said 'you too' to a "
   "waiter who said enjoy your meal. She has forgotten. I have not."),
   k=[("nightshift","2:14 club. I'm here for a thing I said in a lift in 2021."),
      ("halfmoon","My brain's greatest hits album is all things nobody else remembers."),
      ("bluetuesday","I once said 'you too' to a doctor who told me to get well soon.")]),

 dict(a="esi_a", c="healing_corner", m="grateful", h=30, t=(
   "Small thing: I ate lunch today. Sitting down. Not standing over the sink "
   "reading emails. It took eleven minutes and I feel like a different animal."),
   k=[("abena_o","Eleven minutes! The standing-over-the-sink era was rough for me too."),
      ("morningperson","Saving this. Doing it tomorrow."),
      ("velvethour","This is the content I'm here for. The small animal things.")]),

 dict(a="femi_o", c="campus_life", m="anxious", h=4, t=(
   "Final year project due in nine days and my supervisor has not replied to "
   "an email since August. I have started writing it as if he agrees."),
   k=[("keza_k","Writing it as if he agrees is genuinely the correct move. Document every email."),
      ("almostthere","Copy the department head on the next one. Politely. Works more often than you'd think."),
      ("patrick_n","Nine days is enough. I've seen worse turn out fine.")]),

 dict(a="gloria_u", c="vent_zone", m="angry", h=16, t=(
   "A patient's son shouted at me today for something that was not my "
   "decision, not my department and not my fault. I said sorry sir twice. "
   "I would like the two sorries back please."),
   k=[("rehema_j","You can have mine too. I have spares I'd like returned."),
      ("neema_s","The reflex apology. We're trained into it and it costs something."),
      ("diane_mu","Thank you for what you do, for whatever a stranger's thanks is worth today.")]),

 dict(a="secondchance", c="testimonies", m="hopeful", h=40, t=(
   "Two years ago I was sleeping on my cousin's floor in Nyamirambo with "
   "nothing. Today I signed a lease on a one-bedroom. It's small and the "
   "water is unreliable and I cried in the empty sitting room."),
   k=[("borrowedtime","The crying in the empty room. That's the real signature on the lease."),
      ("mangoseason","Congratulations. Two years is both very long and very fast."),
      ("longwayround","Nyamirambo floor to your own keys. That's a whole life change."),
      ("kwame_b","Needed to read this today, honestly.")]),

 dict(a="zainab_h", c="family_issues", m="healing", h=52, t=(
   "I have stopped waiting for my mother to apologise. Not because I forgave "
   "her exactly. More that I noticed I was spending my thirties in a waiting "
   "room she doesn't know exists."),
   k=[("nia_m","The waiting room she doesn't know exists. God."),
      ("wanjiru_w","I'm still in mine. This is the first thing that's made me consider leaving."),
      ("ama_writes","Not forgiveness, just no longer paying rent on the waiting. That's allowed.")]),

 dict(a="kwame_b", c="confessions", m="sad", h=6, t=(
   "I cried in my car outside the office and then went in and ran a meeting "
   "about quarterly targets. Nobody could tell. I don't know if that's a "
   "skill or a warning."),
   k=[("claude_ii","Both. It's both and I say that as someone who has done it for eleven years."),
      ("patrick_n","It's a skill that costs. Mine came due all at once at 34."),
      ("saltwater","Car crying is its own genre. The parking lot holds so much.")]),

 dict(a="morningperson", c="funny_confessions", m="happy", h=8, t=(
   "I have been pronouncing a colleague's name wrong for two years. Today "
   "someone else said it correctly. I have decided to move country."),
   k=[("heavyrotation","Not the moving country. I felt this in my spine."),
      ("greenlight","Just say it right from tomorrow. Nobody will mention it. That's the law."),
      ("mangoseason","Two years is honestly impressive commitment.")]),

 dict(a="farfromhome", c="adulting", m="lonely", h=13, t=(
   "Sundays here are so quiet I can hear the fridge. Back home Sunday was "
   "loud from 6am and I used to complain about it."),
   k=[("ines_g","I'd give something real for the 6am noise right now."),
      ("abena_o","I started calling home on Sunday mornings just to hear the background."),
      ("farfromhome","@abena_o doing this from this Sunday. Thank you.")]),

 dict(a="paperboats", c="regrets", m="sad", h=60, t=(
   "I didn't go to my grandmother's funeral because of a work thing that, I "
   "can now tell you, nobody remembers. Not my boss. Not the client. Nobody "
   "except me, at 3am, roughly twice a month."),
   k=[("tunde_a","Twice a month at 3am is a sentence you're still serving. She'd have commuted it."),
      ("rehema_j","The work thing nobody remembers. That's the cruellest part of all of these."),
      ("diane_mu","My uncle told me grief keeps its own calendar. Yours will ease. Not vanish, ease.")]),

 dict(a="neema_s", c="hot_takes", m="confused", h=18, t=(
   "Unpopular: 'self care' has been sold back to us as things you buy. "
   "Actual self care is mostly boring. It's sleep, it's a hard conversation, "
   "it's not answering at 11pm."),
   k=[("stilllearning","The hard conversation being self care is the part people skip."),
      ("esi_a","Boring is right. Mine this month is a dentist appointment I've moved four times."),
      ("velvethour","I do think the bath helps though. Let me have the bath.")]),
]
