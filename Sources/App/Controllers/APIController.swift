//
//  APIController.swift
//  Flipt-web
//
//  Created by Johann Kerr on 12/5/16.
//
//

import Foundation
import PostgreSQL
import Vapor
import Auth
import HTTP
import Cookies
import Turnstile
import TurnstileCrypto
import TurnstileWeb
import Fluent

final class APIController {
    
    let protect = ProtectMiddleware(error: Abort.custom(status: .unauthorized, message: "Unauthorized"))
    
    func addRoutes(drop:Droplet){
        drop.grouped(BasicAuthenticationMiddleware(), protect).group("api") { api in
            api.get("myBooks", handler: myBooks)
            api.get("me", handler: respond)
            api.post("book", handler: addBook)
            api.get("search", handler:search)
            api.get("near", handler:near)
            api.get("user", Int.self) { request, userId in
                try self.userbooks(request: request, id: userId)
            }
            api.post("updatePic", handler: updateProfilePicture)
            
        }
        
        drop.group("api"){ api in
            api.post("register", handler: registerJSON)
            api.post("login", handler: loginJSON)
        }
        
    }
    
    //Route Functions
    
    func respond(request: Request) throws -> ResponseRepresentable{
//        let userId = try request.user().id?.int ?? 0
//        
        let userName = try request.user().username
        print(userName)
        let user = try MainUser.query().filter("username", userName).all()[0]
        let userId = user.id?.int ?? 0
//
        
        let booksCount = try Book.query().filter("mainuser_id", userId).all().count
        print(booksCount)
//        print(booksCount)
        
        return try JSON(node: ["user":request.user().makeNode(),
        "books":booksCount])
    }
    
 
    
}

//MARK:- Login

extension APIController {
    //MARK:- Register
    func registerJSON(request: Request) throws -> ResponseRepresentable{
        
        guard let username = request.json?["username"]?.string, let password = request.json?["password"]?.string else {
            throw Abort.badRequest
        }
        print(username)
        print(password)
        
        let credentials = UsernamePassword(username: username, password: password)
        
        do {
            let user = try MainUser.register(credentials: credentials)
            print(user)
            return try JSON(node: user.makeNode() )
            //try request.auth.login(credentials)
            //change response
            // return Response(redirect: "/")
        } catch let e as TurnstileError {
            print(e.description)
            return try drop.view.make("register", Node(node: ["flash": e.description]))
        }
        
    }
    
    //MARK:- Login
    func loginJSON(request: Request) throws -> ResponseRepresentable{
        guard let username = request.json?["username"]?.string, let password = request.json?["password"]?.string else {
            throw Abort.badRequest
        }
        
        
        let credentials = UsernamePassword(username: username, password: password)
        do {
            let user = try MainUser.authenticate(credentials: credentials)
            //try request.auth.login(credentials)
            return try JSON(node: user.makeNode())
        } catch let e {
            return try drop.view.make("login", ["flash": "Invalid username or password - \(e)"])
        }
    }
}

//MARK:- User Management 

extension APIController {
    func updateProfilePicture(request:Request) throws -> ResponseRepresentable{
        var success = false
        print("running")
        print(request.json)
        guard let profilePicture = request.json?["profilePic"]?.string else {
            throw Abort.badRequest
        }
        print(profilePicture)
        var user = try request.user()
        dump(user)
        let foundUser = try MainUser.query().filter("username", user.username).first()
        dump(foundUser)
        guard let myUser = foundUser else {
            return Abort.badRequest as! ResponseRepresentable
        }
        
        var updatedUser = myUser
        updatedUser.profilePic = profilePicture
        try updatedUser.save()
        do {
            try updatedUser.save()
            success = true
        }catch {
           success = false
        }
        
        return try JSON(node:["success":success])
        
    }
}


//MARK:- Books

extension APIController {
    //MARK:- User Books
    func userbooks(request:Request, id:Int) throws -> ResponseRepresentable{
        let books = try Book.query().filter("mainuser_id", id).all()
        
        return try JSON(node: books.makeNode())
    }
    
    //MARK:- Add Book
    
    func addBook(request: Request) throws -> ResponseRepresentable{
        
        let title = request.data["title"]?.string ?? ""
        let isbn = request.data["isbn"]?.string ?? ""
        let imgUrl = request.data["imgurl"]?.string ?? ""
        let latitude = request.data["latitude"]?.double ?? 0.0
        let longitude = request.data["longitude"]?.double ?? 0.0
        let publisher = request.data["publisher"]?.string ?? ""
        let author = request.data["author"]?.string ?? ""
        let description = request.data["description"]?.string ?? ""
        let publishYear = request.data["publishYear"]?.string ?? ""
        
        let owner = try request.user()
        
        var book = Book(title: title, isbn: isbn, imgUrl: imgUrl, lat: latitude, long: longitude, mainuser_id: owner.id!, publisher: publisher, author: author, description: description, publishYear: publishYear)
        
        try book.save()
        
        return try JSON(node: book.makeNode())
        
    }
    
    //MARK:- Get Books
    func myBooks(request: Request) throws -> ResponseRepresentable{
        let user = try request.user()
        if let userId = user.id{
            
            let books = try Book.query().filter("mainuser_id", userId).all()
            return try JSON(node: books.makeNode())
        }
        
        return try JSON(node: Book.all().makeNode())
    }
    
    //MARK:- Near
    
    func near(request:Request) throws -> ResponseRepresentable{
        // 40.719503, -73.985142
        let user = try request.user()
        guard let userId = user.id else { return Abort.badRequest as! ResponseRepresentable }
        guard let userInt = userId.int else { return Abort.badRequest as! ResponseRepresentable }
        
        
        
        var latitudeRadians = 0.0
        var longitudeRadians = 0.0
        if let latitude = request.data["lat"]?.double, let longitude = request.data["long"]?.double {
            latitudeRadians = latitude * M_PI/180
            longitudeRadians = longitude * M_PI/180
        }
        
        var foundbooks = [Book]()
        
        findBooks(userId: userInt, within: 1609, from: latitudeRadians, longitude: longitudeRadians) { (books) in
            foundbooks = books
        }
        
        return try JSON(node: foundbooks.makeNode())
    }
    
    //MARK:- Search
    func search(request: Request) throws -> ResponseRepresentable{
        
        if let titlesearch = request.data["title"]?.string {
            print(titlesearch)
            let searchTerm = titlesearch.replacingOccurrences(of: "+", with: " ")
            let books = try Book.query().filter("title",searchTerm).all()
            
            return try JSON(node:books.makeNode())
        }
        if let isbn = request.data["isbn"]?.string{
            let books = try Book.query().filter("isbn", isbn).all()
            return try JSON(node: books.makeNode())
        }
        return try JSON(node: [])
    }
    
    
    
    
}
// MARK: - Helper Functions
extension  APIController {
    func findBooks(userId: Int, within distance:Double, from myLat:Double, longitude myLong:Double, completion:([Book])->()){
        
        let radiusOfEarth = 6371.0
        let angularRadius = distance/radiusOfEarth
        print(myLat)
        print(myLong)
        //        let lat = 0.0
        //        let long = 0.0
        let minLat = myLat - angularRadius
        let maxLat = myLat + angularRadius
        
        let maxT = asin(sin(myLat)/cos(angularRadius))
        
        let deltalon = acos((cos(angularRadius)-sin(maxT)*sin(myLat))/(cos(maxT)*cos(myLat)))
        let minLong = myLong - deltalon
        let maxLong = myLong + deltalon
        

        do {
        // this hits an error when empty double check and write tests
            let books = try Book.query()
                .filter("mainuser_id", Filter.Comparison.notEquals, userId)
                .filter("lat", Filter.Comparison.greaterThan, minLat)
                .filter("lat", Filter.Comparison.lessThan, maxLat)
                .filter("long", Filter.Comparison.greaterThan, minLong)
                .filter("long", Filter.Comparison.lessThan, maxLong)
                .all()
            
            print(books)
            
            var nearBooks = [Book]()
            for book in books {
                let booklat = book.lat
                let booklong = book.long
                print(acos(sin(myLat) * sin(booklat) + cos(myLat) * cos(booklat) * cos(booklong - (myLong))))
                print(angularRadius)
                
                let deltaCheck = acos(sin(myLat) * sin(booklat) + cos(myLat) * cos(booklat) * cos(booklong - (myLong))) <= angularRadius
                if deltaCheck{
                    print("hooray in range")
                    nearBooks.append(book)
                }else{
                    print("nah too far")
                }
            }
            
            completion(nearBooks)
        }catch{
            print("error")
        }
        
        
    }
}
