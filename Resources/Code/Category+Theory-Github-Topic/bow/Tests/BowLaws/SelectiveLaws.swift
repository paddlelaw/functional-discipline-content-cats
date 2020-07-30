import SwiftCheck
import Bow

public class SelectiveLaws<F: Selective & EquatableK> {
    public static func check() {
        identity()
        distributibity()
        associativity()
    }

    private static func identity() {
        property("Identity") <~ forAll { (x: Int) in
            let input = F.pure(Either<Int, Int>.right(x))
            
            return input.select(F.pure(id))
                ==
            input.map { x in x.fold(id, id) }
        }
    }

    private static func distributibity() {
        property("Distributivity") <~ forAll { (a: Int, b: ArrowOf<Int, Int>, c: ArrowOf<Int, Int>) in
            let x = F.pure(Either<Int, Int>.right(a))
            let f = F.pure(b.getArrow)
            let g = F.pure(c.getArrow)
            
            return x.select(F.zipRight(f, g))
                ==
            x.select(f).zipRight(x.select(g))
        }
    }

    private static func associativity() {
        property("Associativity") <~ forAll { (a: Int, b: ArrowOf<Int, Int>, c: ArrowOf<Int, Int>) in
            let x = F.pure(Either<Int, Int>.right(a))
            let y = F.pure(Either<Int, (Int) -> Int>.right(b.getArrow))
            let z = F.pure({ (_: Int) in c.getArrow })

            let m: Kind<F, Either<Int, Either<(Int, Int), Int>>> = x.map { x in x.map(Either.right)^ }
            let n: Kind<F, (Int) -> Either<(Int, Int), Int>> = y.map { y in { a in y.bimap({ l in (l, a) }, { r in r(a) }) }}
            let q: Kind<F, ((Int, Int)) -> Int> = z.map { z in { a in z(a.0)(a.1) } }

            return x.select(y.select(z))
                ==
            m.select(n).select(q)
        }
    }
}
