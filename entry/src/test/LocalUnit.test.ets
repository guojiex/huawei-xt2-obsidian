import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { clampContentRatio, clampNavigationWidth, isSingleLandscapeWindow, navigationWidth } from '../main/ets/model/PaneLayout';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });

    it('single landscape is derived from actual window geometry', 0, () => {
      expect(isSingleLandscapeWindow(780, 380)).assertEqual(true);
      expect(isSingleLandscapeWindow(709, 790)).assertEqual(false);
      expect(isSingleLandscapeWindow(1061, 790)).assertEqual(false);
      expect(isSingleLandscapeWindow(380, 790)).assertEqual(false);
    });

    it('shared pane widths respect ratio limits and 240vp pane minimums', 0, () => {
      const landscapeNav: number = navigationWidth(780, -1, 1, 1);
      expect(landscapeNav).assertLarger(259);
      expect(landscapeNav).assertLess(261);
      expect(clampNavigationWidth(1, 1061, 2, 2)).assertEqual(240);
      expect(clampNavigationWidth(2000, 1061, 2, 2)).assertLess(489);
      const splitRatio: number = clampContentRatio(0, 676);
      expect(splitRatio).assertLarger(0.35);
      expect(splitRatio).assertLess(0.36);
      expect(clampContentRatio(0.5, 100)).assertEqual(0.5);
    });
  });
}
