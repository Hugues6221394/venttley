"""What the classifier does with what the model saw.

These tests exist because the alternative way to check this logic is to keep
explicit images around to run it against, which is not something anyone should
have to do to verify a mapping from label names to a verdict. The model's
detections are just dictionaries and the decision is pure, so the decision gets
tested directly and the model is left to be the model.

The class that matters most is TestNeverBlocksOrdinaryPhotos. Blocking is the
only destructive outcome — it deletes somebody's post — and a wrongly blocked
holiday photo is a reason to leave an app. Every ordinary thing NudeNet reports
about a clothed human being is asserted here to come back clean.

Run: python3 -m pytest test_decide.py -q   (or ./run_tests.py with no pytest)
"""

from app import (
    BLOCK_AT,
    NUDITY_VEIL_AT,
    SUGGESTIVE_AT,
    decide,
)


def d(name, score):
    return {"class": name, "score": score}


class TestBlocksConfidentNudity:
    """Exposed nudity, and the model is sure. This is the only path to a block."""

    def test_each_exposed_label_blocks_at_high_confidence(self):
        for label in (
            "FEMALE_GENITALIA_EXPOSED",
            "MALE_GENITALIA_EXPOSED",
            "ANUS_EXPOSED",
            "FEMALE_BREAST_EXPOSED",
            "BUTTOCKS_EXPOSED",
        ):
            assert decide([d(label, 0.95)])[0] == "blocked", label

    def test_the_real_test_image_blocks(self):
        # The exact detections the live classifier returned for the explicit
        # image used in testing. It must now be refused, not merely veiled.
        real = [
            d("FEMALE_BREAST_EXPOSED", 0.823635995388031),
            d("ARMPITS_EXPOSED", 0.5460659265518188),
            d("BELLY_EXPOSED", 0.4041491448879242),
        ]
        assert decide(real)[0] == "blocked"

    def test_blocked_wins_regardless_of_order(self):
        # The model emits detections in its own order. A strong block must not
        # be downgraded by a milder detection that arrives after it.
        strong = d("MALE_GENITALIA_EXPOSED", 0.9)
        mild = d("ANUS_COVERED", 0.9)
        assert decide([strong, mild])[0] == "blocked"
        assert decide([mild, strong])[0] == "blocked"

    def test_exactly_at_the_threshold_blocks(self):
        assert decide([d("ANUS_EXPOSED", BLOCK_AT)])[0] == "blocked"


class TestVeilsUncertainNudity:
    """The model thinks it saw nudity but is not sure. Veil, do not delete."""

    def test_mid_confidence_nudity_is_veiled_not_blocked(self):
        just_below = BLOCK_AT - 0.01
        for label in ("FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED"):
            assert decide([d(label, just_below)])[0] == "sensitive", label

    def test_low_confidence_nudity_is_clean(self):
        # Below the veil threshold the model is essentially guessing, and
        # blurring on a guess trains people to ignore the blur.
        assert decide([d("FEMALE_BREAST_EXPOSED", NUDITY_VEIL_AT - 0.01)])[0] == "clean"

    def test_clothed_but_suggestive_never_blocks(self):
        # Covered is not exposed. A swimsuit photo at 0.99 confidence is still
        # a swimsuit photo, and deleting it would be the worse error.
        for label in (
            "FEMALE_GENITALIA_COVERED",
            "MALE_GENITALIA_COVERED",
            "ANUS_COVERED",
        ):
            assert decide([d(label, 0.99)])[0] == "sensitive", label


class TestNeverBlocksOrdinaryPhotos:
    """The expensive mistake. None of these may ever block, at any confidence."""

    ORDINARY = [
        "FACE_FEMALE",
        "FACE_MALE",
        "FEMALE_BREAST_COVERED",
        "BELLY_COVERED",
        "BELLY_EXPOSED",
        "ARMPITS_COVERED",
        "ARMPITS_EXPOSED",
        "FEET_COVERED",
        "FEET_EXPOSED",
        "BUTTOCKS_COVERED",
    ]

    def test_none_of_them_block_even_at_full_confidence(self):
        for label in self.ORDINARY:
            assert decide([d(label, 1.0)])[0] != "blocked", label

    def test_none_of_them_even_veil(self):
        # A person in a vest top with bare feet is not a moderation event.
        for label in self.ORDINARY:
            assert decide([d(label, 1.0)])[0] == "clean", label

    def test_all_of_them_together_are_still_clean(self):
        # A beach photo of clothed people lights up most of this list at once.
        assert decide([d(l, 0.9) for l in self.ORDINARY])[0] == "clean"

    def test_a_covered_breast_at_business_suit_confidence_is_clean(self):
        # Measured: a woman in a business suit returned FEMALE_BREAST_COVERED
        # at 0.46 and FACE_FEMALE at 0.86 from the live model.
        assert decide([d("FEMALE_BREAST_COVERED", 0.46), d("FACE_FEMALE", 0.86)])[0] == "clean"

    def test_an_unknown_future_label_never_blocks(self):
        # A model update could introduce labels. An unrecognised one must not
        # start deleting posts after a dependency bump with no code change.
        assert decide([d("SOME_FUTURE_LABEL", 1.0)])[0] == "clean"


class TestRobustness:
    def test_no_detections_is_clean(self):
        assert decide([])[0] == "clean"
        assert decide(None)[0] == "clean"

    def test_unnamed_detections_are_ignored(self):
        assert decide([{"score": 0.99}, d("", 0.99)])[0] == "clean"

    def test_missing_or_junk_score_does_not_raise_or_block(self):
        assert decide([{"class": "FEMALE_GENITALIA_EXPOSED"}])[0] == "clean"
        assert decide([{"class": "FEMALE_GENITALIA_EXPOSED", "score": "abc"}])[0] == "clean"

    def test_the_highest_score_per_label_is_reported(self):
        _, labels = decide([d("BUTTOCKS_EXPOSED", 0.4), d("BUTTOCKS_EXPOSED", 0.8)])
        assert labels["BUTTOCKS_EXPOSED"] == 0.8

    def test_thresholds_are_ordered_sensibly(self):
        # A misconfiguration that put the veil line above the block line would
        # silently make blocking unreachable.
        assert NUDITY_VEIL_AT < BLOCK_AT
        assert 0 < SUGGESTIVE_AT <= 1
