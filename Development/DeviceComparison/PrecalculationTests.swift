import XCTest
import Metal
@testable import GradientsKit

#if PRECALC_COMPARISON
final class PrecalculationTests:XCTestCase {
    func testCacheLayoutAndCheckedSizes() {
        XCTAssertEqual(GradientPrecalculationBuffers.byteCount(width:1170,height:2532),128968)
        XCTAssertNil(GradientPrecalculationBuffers.byteCount(width:0,height:2532))
        XCTAssertNil(GradientPrecalculationBuffers.byteCount(width:Int.max,height:Int.max))
    }
    func testSlotsAreIndependentAndExtentChecked() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let resources=try XCTUnwrap(GradientPrecalculationBuffers(device:device,width:1170,height:2532))
        XCTAssertEqual(resources.slots.count,3)
        XCTAssertFalse(resources.slots[0] === resources.slots[1])
        XCTAssertFalse(resources.slots[1] === resources.slots[2])
        for buffer in resources.slots {
            XCTAssertEqual(buffer.length,128968)
            XCTAssertEqual(buffer.storageMode,.private)
            XCTAssertEqual(buffer.hazardTrackingMode,.tracked)
        }
        XCTAssertNil(resources.buffer(slot:0,width:1169,height:2532))
        XCTAssertNil(resources.buffer(slot:3,width:1170,height:2532))
    }
    @MainActor func testPreparedPipelinesAndBothThemes() throws {
        let controller=try GradientViewController()
        XCTAssertGreaterThanOrEqual(controller.gpu.preparation.maxTotalThreadsPerThreadgroup,64)
        for dark in [true,false] {
            let frame=controller.session.frame(at:1,size:CGSize(width:390,height:844),dark:dark)
            XCTAssertEqual(frame.uniforms[24],3)
        }
    }
}
#endif
