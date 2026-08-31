"""What the classifier does with what the model saw.

These tests exist because the alternative way to check this logic is to keep
explicit images around to run it against, which is not something anyone should
have to do to verify a mapping from label names to a verdict. The model's
detections are just dictionaries; the decision is pure; so the decision gets
tested directly and the model is left to be the model.

Run: python3 -m pytest test_decide.py -q
"""

from app import decide


def d(name, score):
    return {"class": name, "score": score}


class TestClean:
    def test_no_detections_is_clean(self):
        assert decide([])[0] == "clean"
        assert decide(None)[0] == "clean"

    def test_a_face_is_not_nudity(self):
        # NudeNet reports plenty of benign regions. None of them are in either
        # set, and a photo of a person must not be quarantined for containing
        # a person.
        verdict, labels = decide([d("FACE_FEMALE", 0.99), d("BELLY_COVERED", 0.8)])
        assert verdict == "clean"
        assert labels["FACE_FEMALE"] == 0.99

    def test_a_low_confidence_hit_does_not_trip_it(self):
        assert decide([d("FEMALE_BREAST_EXPOSED", 0.11)])[0] == "clean"


class TestSensitive:
    def test_exposed_breast_quarantines(self):
        assert decide([d("FEMALE_BREAST_EXPOSED", 0.9)])[0] == "sensitive"

    def test_buttocks_quarantines(self):
        assert decide([d("BUTTOCKS_EXPOSED", 0.7)])[0] == "sensitive"

    def test_covered_genitalia_quarantines_rather_than_blocks(self):
        # Covered is a judgement call, and a judgement call is what the
        # sensitive state is for. Blocking it outright would delete swimwear.
        assert decide([d("FEMALE_GENITALIA_COVERED", 0.95)])[0] == "sensitive"


class TestBlocked:
    def test_exposed_genitalia_blocks(self):
        assert decide([d("FEMALE_GENITALIA_EXPOSED", 0.6)])[0] == "blocked"
        assert decide([d("MALE_GENITALIA_EXPOSED", 0.6)])[0] == "blocked"
        assert decide([d("ANUS_EXPOSED", 0.6)])[0] == "blocked"

    def test_blocked_wins_regardless_of_order(self):
        # The model emits detections in its own order. A strong block must not
        # be downgraded by a milder detection that happens to arrive after it —
        # this is the ordering bug the extracted function makes testable.
        strong_first = [d("MALE_GENITALIA_EXPOSED", 0.9), d("BUTTOCKS_EXPOSED", 0.9)]
        strong_last = [d("BUTTOCKS_EXPOSED", 0.9), d("MALE_GENITALIA_EXPOSED", 0.9)]
        assert decide(strong_first)[0] == "blocked"
        assert decide(strong_last)[0] == "blocked"


class TestRobustness:
    def test_unnamed_detections_are_ignored_not_crashed_on(self):
        assert decide([{"score": 0.9}, d("", 0.9)])[0] == "clean"

    def test_a_label_the_app_does_not_know_is_not_treated_as_unsafe(self):
        # A model update could introduce new labels. An unknown label must not
        # silently become a block — that would start refusing ordinary photos
        # after a dependency bump, with no code change to point at.
        assert decide([d("SOME_FUTURE_LABEL", 0.99)])[0] == "clean"

    def test_the_highest_score_per_label_is_kept(self):
        _, labels = decide([d("BUTTOCKS_EXPOSED", 0.4), d("BUTTOCKS_EXPOSED", 0.8)])
        assert labels["BUTTOCKS_EXPOSED"] == 0.8

    def test_missing_score_does_not_raise(self):
        assert decide([{"class": "FACE_FEMALE"}])[0] == "clean"
