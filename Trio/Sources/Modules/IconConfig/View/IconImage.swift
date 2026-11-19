
import SwiftUI

struct IconImage: View {
    var icon: Icon_

    var body: some View {
        Label {
            Text(icon.displayName)
        } icon: {
            Image(icon.assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(minHeight: 57, maxHeight: 1024)
                .cornerRadius(10)
                .shadow(radius: 10)
                .padding()
        }
        .labelStyle(.iconOnly)
        .accessibilityHidden(true)
    }
}

struct IconImage_Previews: PreviewProvider {
    static var previews: some View {
        IconImage(icon: Icon_.primary)
            .previewInterfaceOrientation(.portrait)
    }
}
