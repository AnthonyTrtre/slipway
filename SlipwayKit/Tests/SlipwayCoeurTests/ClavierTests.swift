import Testing
@testable import SlipwayCoeur

@Suite("Tables clavier")
struct ClavierTests {
    @Test func tableMacHIDBijective() {
        let macs = TableTouchesMac.paires.map(\.mac)
        let hids = TableTouchesMac.paires.map(\.hid)
        #expect(Set(macs).count == macs.count, "code Mac en double")
        #expect(Set(hids).count == hids.count, "usage HID en double")
        for (mac, hid) in TableTouchesMac.paires {
            #expect(TableTouchesMac.usage(pourCodeMac: mac) == hid)
            #expect(TableTouchesMac.codeMac(pourUsage: hid) == mac)
        }
    }

    @Test func toutesLesLettresChiffresEtFonctionsSontCouvertes() {
        for hid in UInt16(0x04)...0x27 { #expect(TableTouchesMac.codeMac(pourUsage: hid) != nil, "usage 0x\(String(hid, radix: 16))") }
        for hid in UInt16(0x3A)...0x45 { #expect(TableTouchesMac.codeMac(pourUsage: hid) != nil, "F\(hid - 0x39)") }
        for hid in UInt16(0xE0)...0xE7 { #expect(TableTouchesMac.codeMac(pourUsage: hid) != nil) }
        #expect(TableTouchesMac.paires.count >= 120)
    }

    @Test("Quelques correspondances connues", arguments: [
        (UInt16(0x00), UInt16(0x04)), (0x0C, 0x14), (0x31, 0x2C), (0x24, 0x28), (0x35, 0x29), (0x37, 0xE3), (0x36, 0xE7),
        (0x7B, 0x50), (0x7A, 0x3A), (0x6F, 0x45), (0x3F, 0x0300), (0x0A, 0x64), (0x32, 0x35), (0x4C, 0x58),
    ])
    func correspondances(_ paire: (UInt16, UInt16)) {
        #expect(TableTouchesMac.usage(pourCodeMac: paire.0) == paire.1)
    }

    @Test func codesInconnus() {
        #expect(TableTouchesMac.usage(pourCodeMac: 0xFF) == nil)
        #expect(TableTouchesMac.codeMac(pourUsage: 0x0001) == nil)
    }

    @Test func modificateursAllerRetour() {
        for bits in 0..<(1 << 10) {
            let m = Modificateurs(rawValue: UInt32(bits))
            #expect(DrapeauxMac.versModificateurs(DrapeauxMac.depuisModificateurs(m)) == m)
        }
    }

    @Test func drapeauxSansCotesAttribuesAGauche() {
        #expect(DrapeauxMac.versModificateurs(DrapeauxMac.cmd | DrapeauxMac.maj) == [.cmdGauche, .majGauche])
        #expect(DrapeauxMac.versModificateurs(DrapeauxMac.cmd | DrapeauxMac.cmdDroit) == [.cmdDroit])
        #expect(DrapeauxMac.versModificateurs(DrapeauxMac.paveNumerique) == [])
    }

    @Test func flagsChangedAppuiEtRelachement() {
        let majGaucheEnfoncee = DrapeauxMac.maj | DrapeauxMac.majGauche
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x38, drapeaux: majGaucheEnfoncee) == true)
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x38, drapeaux: 0) == false)
        // Maj droite relâchée pendant que Maj gauche reste enfoncée.
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x3C, drapeaux: majGaucheEnfoncee) == false)
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x3C, drapeaux: majGaucheEnfoncee | DrapeauxMac.majDroit) == true)
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x3F, drapeaux: DrapeauxMac.fn) == true)
        #expect(DrapeauxMac.estEnfoncee(codeMac: 0x00, drapeaux: 0) == nil)   // A n'est pas un modificateur
    }

    @Test func correspondanceExacteDesRaccourcis() {
        let m: Modificateurs = [.ctrlGauche, .optionDroit, .cmdGauche, .verrMaj]
        #expect(m.correspondExactement(a: [.ctrl, .option, .cmd]))
        #expect(!m.correspondExactement(a: [.ctrl, .cmd]))
        #expect(!Modificateurs([.ctrlGauche, .optionGauche, .cmdGauche, .majGauche]).correspondExactement(a: [.ctrl, .option, .cmd]))
    }

    @Test func touchesSysteme() {
        for (nx, hid) in TableTouchesSysteme.paires {
            #expect(TableTouchesSysteme.usage(pourTypeNX: nx) == hid)
            #expect(TableTouchesSysteme.typeNX(pourUsage: hid) == nx)
        }
        let data1 = TableTouchesSysteme.encoderData1(nx: 16, enfonce: true, repetition: false)
        #expect(data1 == 0x0010_0A00)
        let d = TableTouchesSysteme.decoderData1(data1)
        #expect(d?.nx == 16 && d?.enfonce == true && d?.repetition == false)
        #expect(TableTouchesSysteme.decoderData1(TableTouchesSysteme.encoderData1(nx: 0, enfonce: false, repetition: true))?.enfonce == false)
        #expect(TableTouchesSysteme.decoderData1(0x0010_0500) == nil)
    }

    @Test func phasesDeDefilement() {
        for p in [PhaseDefilement.aucune, .debut, .changement, .fin, .annule, .peutCommencer] {
            #expect(PhasesMac.phase(depuisQuartz: PhasesMac.quartz(depuis: p)) == p)
        }
        for i in [PhaseInertie.aucune, .debut, .enCours, .fin] {
            #expect(PhasesMac.inertie(depuisQuartz: PhasesMac.quartz(depuis: i)) == i)
        }
        #expect(PhasesMac.phase(depuisQuartz: 3) == .aucune)
        #expect(PhasesMac.inertie(depuisQuartz: 99) == .aucune)
    }
}
