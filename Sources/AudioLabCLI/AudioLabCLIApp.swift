import Foundation

@main
struct AudioLabCLIApp {
    static func main() {
        let cli = CLI(arguments: CommandLine.arguments)
        cli.run()
    }
}
